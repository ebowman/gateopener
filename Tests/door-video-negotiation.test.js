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
    this.localDescription = { type: "offer", sdp: FakePeerConnection.initialSdp };
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
FakePeerConnection.initialSdp = "v=0\r\na=candidate:host 1 udp 1 192.0.2.1 40000 typ host\r\n";

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
  FakePeerConnection.initialGatheringState = "gathering";
  FakePeerConnection.initialSdp = "v=0\r\na=candidate:host 1 udp 1 192.0.2.1 40000 typ host\r\n";
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

function setSdp(pc, candidateLines) {
  pc.localDescription.sdp = "v=0\r\n" + candidateLines.join("\r\n") + "\r\n";
}

function validCandidate(type = "srflx", address = "203.0.113.1") {
  return `a=candidate:qualified 1 udp 2122260223 ${address} 40000 typ ${type}`;
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
  pc.localDescription.sdp += validCandidate() + "\r\n";
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
}

async function stuckGatheringWithEarlySrflxPublishesOneDeadlineSnapshot() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  clock.advance(1100);
  setSdp(pc, [
    "a=candidate:host 1 udp 1 192.0.2.1 40000 typ host",
    validCandidate(),
  ]);
  const expectedSnapshot = pc.localDescription.sdp;
  assert.equal(context.__state.offerReady, false);
  clock.advance(13899);
  assert.equal(context.__state.offerReady, false);
  clock.advance(1);
  const sdp = await result;
  assert.equal(sdp, expectedSnapshot);
  assert.equal(context.__state.offerSdp, expectedSnapshot);
  assert.equal(context.__state.offerReady, true);
  pc.localDescription.sdp += validCandidate("relay", "198.51.100.2") + "\r\n";
  pc.iceGatheringState = "complete";
  pc.dispatch("icegatheringstatechange");
  assert.equal(context.__state.offerSdp, expectedSnapshot);
  assert.ok(context.__diag.some((line) =>
    line.includes("ICE snapshot published: deadline with gathered candidate")
  ));
  assert.equal(pc.listenerCount(), 0);
  assert.equal(clock.timers.size, 0);
}

async function stuckGatheringWithRelayPublishesAtDeadline() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  setSdp(pc, [validCandidate("relay", "198.51.100.2")]);
  clock.advance(15000);
  assert.equal(await result, pc.localDescription.sdp);
}

async function validIPv6SrflxPublishesAtDeadline() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  setSdp(pc, [validCandidate("srflx", "64:ff9b::cb00:7101")]);
  clock.advance(15000);
  assert.equal(await result, pc.localDescription.sdp);
}

async function validCandidateExtensionsAndMappedIPv6PublishAtDeadline() {
  for (const candidate of [
    validCandidate() +
      " raddr 192.0.2.1 rport 3478 generation 0 network-cost 999 ufrag abc",
    validCandidate("srflx", "::ffff:203.0.113.1") +
      " raddr :: rport 0 generation 0 network-cost 999 ufrag abc",
  ]) {
    const { context, clock } = loadPage();
    const { result, pc } = await beginNegotiation(context);
    setSdp(pc, [candidate]);
    clock.advance(15000);
    assert.equal(await result, pc.localDescription.sdp);
  }
}

async function timeoutCaseRejects(candidateLines) {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  if (candidateLines !== null) setSdp(pc, candidateLines);
  if (candidateLines === null) pc.localDescription = null;
  clock.advance(15000);
  await expectRejectsWithCode(result, "ice-gathering-timeout");
  assert.equal(context.__state.offerReady, false);
  assert.equal(context.__state.offerSdp, null);
  assert.equal(pc.listenerCount(), 0);
  assert.equal(clock.timers.size, 0);
}

async function candidateEventWithoutActualSdpRejects() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  pc.onicecandidate({
    candidate: { candidate: validCandidate().substring(2) },
  });
  clock.advance(15000);
  await expectRejectsWithCode(result, "ice-gathering-timeout");
  assert.equal(context.__state.offerReady, false);
}

async function malformedHostOnlyAndMissingSdpReject() {
  await timeoutCaseRejects([
    "a=candidate:host 1 udp 1 192.0.2.1 40000 typ host",
  ]);
  await timeoutCaseRejects([
    "a=candidate:bad typ srflx",
    "a=x:typ srflx",
    "a=candidate:bad 1 tcp 1 203.0.113.1 40000 typ relay",
    "a=candidate:bad 0 udp 1 203.0.113.1 40000 typ srflx",
    "a=candidate:bad 1 udp 1 not-an-ip 40000 typ srflx",
  ]);
  await timeoutCaseRejects([
    "a=candidate:bad 1e0 udp 1 203.0.113.1 40000 typ srflx",
    "a=candidate:bad 1 udp 1e0 203.0.113.1 40000 typ srflx",
    "a=candidate:bad 1 udp 1 203.0.113.1 4e4 typ srflx",
    "a=candidate:bad 1 udp 1 203.0.113.1:: 40000 typ srflx",
    "a=candidate:bad 1 udp 1 203.0.113.1 40000 typ srflx raddr invalid",
    "a=candidate:bad 1 udp 1 203.0.113.1 40000 typ srflx rport 1e0",
    "a=candidate:bad 1 udp 1 203.0.113.1 40000 typ srflx rport 65536",
    "a=candidate:bad 1 udp 1 203.0.113.1 40000 typ srflx generation",
  ]);
  await timeoutCaseRejects([]);
  await timeoutCaseRejects(null);
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

async function finalPublicationLosesQualifyingCandidateRejects() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  setSdp(pc, [validCandidate()]);
  clock.advance(15000);
  setSdp(pc, ["a=candidate:host 1 udp 1 192.0.2.1 40000 typ host"]);

  await expectRejectsWithCode(result, "ice-gathering-timeout");
  assert.equal(context.__state.offerReady, false);
  assert.equal(context.__state.offerSdp, null);
}

async function closeAfterDeadlineFallbackBeforePublicationRejects() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  setSdp(pc, [validCandidate()]);
  clock.advance(15000);
  pc.close();

  await expectRejectsWithCode(result, "ice-gathering-closed");
  assert.equal(context.__state.offerReady, false);
  assert.ok(context.__diag.some((line) =>
    line.includes("negotiation failed: ice-gathering-closed")
  ));
}

async function replacementAfterDeadlineFallbackBeforePublicationRejects() {
  const { context, clock } = loadPage();
  const { result } = await beginNegotiation(context);
  const pc = FakePeerConnection.instances[0];
  setSdp(pc, [validCandidate()]);
  clock.advance(15000);
  context.__state.pc = new FakePeerConnection();

  await expectRejectsWithCode(result, "ice-gathering-closed");
  assert.equal(context.__state.offerReady, false);
  assert.ok(context.__diag.some((line) =>
    line.includes("negotiation failed: ice-gathering-closed")
  ));
}

async function lateCompletionAfterTimeoutCannotPublishOffer() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  clock.advance(15000);
  await expectRejectsWithCode(result, "ice-gathering-timeout");
  pc.localDescription.sdp += validCandidate() + "\r\n";
  pc.iceGatheringState = "complete";
  pc.dispatch("icegatheringstatechange");
  await Promise.resolve();
  assert.equal(context.__state.offerReady, false);
  assert.equal(context.__state.offerSdp, null);
}

(async () => {
  await lateCompletionAfterEightSecondsUsesFinalSdp();
  await quickCompletionIsUnchanged();
  await stuckGatheringWithEarlySrflxPublishesOneDeadlineSnapshot();
  await stuckGatheringWithRelayPublishesAtDeadline();
  await validIPv6SrflxPublishesAtDeadline();
  await validCandidateExtensionsAndMappedIPv6PublishAtDeadline();
  await candidateEventWithoutActualSdpRejects();
  await malformedHostOnlyAndMissingSdpReject();
  await closeDuringGatheringRejectsAndCleansUp();
  await closeAfterGatheringBeforePublicationRejectsWithDiagnostic();
  await replacementAfterGatheringBeforePublicationRejectsWithDiagnostic();
  await finalPublicationLosesQualifyingCandidateRejects();
  await closeAfterDeadlineFallbackBeforePublicationRejects();
  await replacementAfterDeadlineFallbackBeforePublicationRejects();
  await lateCompletionAfterTimeoutCannotPublishOffer();
  console.log("door-video negotiation tests passed");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
