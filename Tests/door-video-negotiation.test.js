#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

class FakeClock {
  constructor() {
    this.now = 0;
    this.nextId = 1;
    this.timers = new Map();
  }

  setTimeout(callback, delay) {
    const id = this.nextId++;
    this.timers.set(id, { at: this.now + delay, callback });
    return id;
  }

  clearTimeout(id) {
    this.timers.delete(id);
  }

  advance(ms) {
    const target = this.now + ms;
    while (true) {
      const due = [...this.timers.entries()]
        .filter(([, timer]) => timer.at <= target)
        .sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      this.now = due[1].at;
      this.timers.delete(due[0]);
      due[1].callback();
    }
    this.now = target;
  }
}

class FakePeerConnection {
  constructor() {
    this.iceGatheringState = FakePeerConnection.initialGatheringState;
    this.connectionState = "new";
    this.signalingState = "stable";
    this.localDescription = null;
    this.listeners = new Map();
    FakePeerConnection.instances.push(this);
  }

  addEventListener(name, callback) {
    if (!this.listeners.has(name)) this.listeners.set(name, new Set());
    this.listeners.get(name).add(callback);
  }

  removeEventListener(name, callback) {
    this.listeners.get(name)?.delete(callback);
  }

  dispatch(name) {
    for (const callback of [...(this.listeners.get(name) || [])]) callback();
    const propertyHandler = this["on" + name];
    if (propertyHandler) propertyHandler();
  }

  listenerCount() {
    return [...this.listeners.values()].reduce((sum, entries) => sum + entries.size, 0);
  }

  addTransceiver() {}
  createDataChannel() {}
  async createOffer() { return { type: "offer", sdp: "initial" }; }
  async setLocalDescription() {
    this.localDescription = { type: "offer", sdp: "v=0\r\na=candidate:host typ host\r\n" };
  }
  close() {
    this.connectionState = "closed";
    this.signalingState = "closed";
    this.dispatch("connectionstatechange");
    this.dispatch("signalingstatechange");
  }
}
FakePeerConnection.instances = [];
FakePeerConnection.initialGatheringState = "gathering";

function makeElement() {
  return {
    addEventListener() {},
    getContext() { return {}; },
    play() { return Promise.resolve(); },
    paused: true,
    readyState: 0,
    srcObject: null,
    videoWidth: 0,
    videoHeight: 0,
  };
}

function loadPage() {
  const clock = new FakeClock();
  FakePeerConnection.instances = [];
  const htmlPath = path.join(__dirname, "..", "Resources", "door-video.html");
  const html = fs.readFileSync(htmlPath, "utf8");
  const script = html.match(/<script>([\s\S]*)<\/script>/)[1];
  const elements = { v: makeElement(), c: makeElement() };
  class FakeDate extends Date {
    constructor(...args) {
      super(...(args.length ? args : [clock.now]));
    }
    static now() { return clock.now; }
  }
  const context = {
    console: { log() {} },
    Date: FakeDate,
    document: { getElementById: (id) => elements[id] },
    MediaStream: class {},
    RTCPeerConnection: FakePeerConnection,
    setTimeout: clock.setTimeout.bind(clock),
    clearTimeout: clock.clearTimeout.bind(clock),
    setInterval: () => 1,
    clearInterval() {},
  };
  context.window = context;
  vm.createContext(context);
  vm.runInContext(script, context, { filename: "Resources/door-video.html" });
  return { context, clock };
}

async function beginNegotiation(context) {
  const result = context.startNegotiation();
  for (let i = 0; i < 5; i++) await Promise.resolve();
  return { result, pc: FakePeerConnection.instances[0] };
}

async function expectRejectsWithCode(promise, code) {
  try {
    await promise;
    assert.fail("expected negotiation to reject");
  } catch (error) {
    assert.equal(error.code, code);
  }
}

async function lateCompletionAfterEightSecondsUsesFinalSdp() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  clock.advance(10500);
  assert.equal(context.__state.offerReady, false);
  pc.localDescription.sdp += "a=candidate:late 1 udp 1 203.0.113.1 40000 typ srflx\r\n";
  pc.iceGatheringState = "complete";
  pc.dispatch("icegatheringstatechange");

  const sdp = await result;
  assert.match(sdp, /typ srflx/);
  assert.equal(context.__state.offerReady, true);
  assert.equal(pc.listenerCount(), 0);
  assert.equal(clock.timers.size, 0);
}

async function quickCompletionIsUnchanged() {
  const { context } = loadPage();
  FakePeerConnection.initialGatheringState = "complete";
  const result = context.startNegotiation();
  for (let i = 0; i < 5; i++) await Promise.resolve();
  const pc = FakePeerConnection.instances[0];
  const sdp = await result;
  assert.equal(sdp, pc.localDescription.sdp);
  assert.equal(context.__state.offerReady, true);
  assert.equal(pc.listenerCount(), 0);
  FakePeerConnection.initialGatheringState = "gathering";
}

async function timeoutRejectsWithoutPublishingOffer() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  clock.advance(15000);
  await expectRejectsWithCode(result, "ice-gathering-timeout");
  assert.equal(context.__state.offerReady, false);
  assert.equal(context.__state.offerSdp, null);
  assert.equal(pc.listenerCount(), 0);
  assert.equal(clock.timers.size, 0);
}

async function closeDuringGatheringRejectsAndCleansUp() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  context.closeSession();
  await expectRejectsWithCode(result, "ice-gathering-closed");
  assert.equal(context.__state.offerReady, false);
  assert.ok(context.__diag.some((line) => line.includes("negotiation failed: ice-gathering-closed")));
  assert.equal(pc.listenerCount(), 0);
  assert.equal(clock.timers.size, 0);
}

async function closeAfterGatheringBeforePublicationRejectsWithDiagnostic() {
  const { context } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  pc.iceGatheringState = "complete";
  pc.dispatch("icegatheringstatechange");
  pc.close();

  await expectRejectsWithCode(result, "ice-gathering-closed");
  assert.equal(context.__state.offerReady, false);
  assert.equal(context.__state.offerSdp, null);
  assert.ok(context.__diag.some((line) => line.includes("negotiation failed: ice-gathering-closed")));
}

async function replacementAfterGatheringBeforePublicationRejectsWithDiagnostic() {
  const { context } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  pc.iceGatheringState = "complete";
  pc.dispatch("icegatheringstatechange");
  context.__state.pc = new FakePeerConnection();

  await expectRejectsWithCode(result, "ice-gathering-closed");
  assert.equal(context.__state.offerReady, false);
  assert.equal(context.__state.offerSdp, null);
  assert.ok(context.__diag.some((line) => line.includes("negotiation failed: ice-gathering-closed")));
}

async function lateCompletionAfterTimeoutCannotPublishOffer() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  clock.advance(15000);
  await expectRejectsWithCode(result, "ice-gathering-timeout");
  pc.localDescription.sdp += "a=candidate:late typ srflx\r\n";
  pc.iceGatheringState = "complete";
  pc.dispatch("icegatheringstatechange");
  await Promise.resolve();
  assert.equal(context.__state.offerReady, false);
  assert.equal(context.__state.offerSdp, null);
}

(async () => {
  await lateCompletionAfterEightSecondsUsesFinalSdp();
  await quickCompletionIsUnchanged();
  await timeoutRejectsWithoutPublishingOffer();
  await closeDuringGatheringRejectsAndCleansUp();
  await closeAfterGatheringBeforePublicationRejectsWithDiagnostic();
  await replacementAfterGatheringBeforePublicationRejectsWithDiagnostic();
  await lateCompletionAfterTimeoutCannotPublishOffer();
  console.log("door-video negotiation tests passed");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
