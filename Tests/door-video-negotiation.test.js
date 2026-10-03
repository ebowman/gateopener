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
    this.remoteDescription = null;
    this.listeners = new Map();
    // Records addTransceiver()/createDataChannel() calls IN ORDER, so tests
    // can assert m-line order (audio/video/datachannel) and the audio
    // transceiver's direction/track (bead gateopener-1pm.3: call mode vs.
    // view mode).
    this.transceivers = [];
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

  addTransceiver(trackOrKind, init) {
    const isTrack = trackOrKind && typeof trackOrKind === "object";
    this.transceivers.push({
      kind: isTrack ? trackOrKind.kind : trackOrKind,
      direction: init && init.direction,
      track: isTrack ? trackOrKind : null,
    });
  }
  createDataChannel(label) {
    this.transceivers.push({ kind: "datachannel", label });
  }
  async createOffer() { return { type: "offer", sdp: "initial" }; }
  async setLocalDescription() {
    this.localDescription = { type: "offer", sdp: FakePeerConnection.initialSdp };
  }
  async setRemoteDescription(desc) {
    this.remoteDescription = desc;
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

// Fake mic track/stream for call-mode tests (bead gateopener-1pm.3).
// track.stop()/track.enabled are recorded so a future test could assert on
// them; only `kind`/`label` are read by door-video.html itself today.
function makeFakeMicTrack(label = "Fake Mic") {
  return {
    kind: "audio",
    label,
    enabled: true,
    stopped: false,
    stop() { this.stopped = true; },
  };
}

function makeFakeMicStream(track) {
  return {
    getAudioTracks: () => [track],
    getTracks: () => [track],
  };
}

// `options.getUserMedia`, when provided, replaces the default
// navigator.mediaDevices.getUserMedia fake entirely (e.g. to simulate a
// rejection). Default: resolves with a stream wrapping `options.micTrack`
// (or a fresh fake track).
function loadPage(options = {}) {
  const clock = new FakeClock();
  FakePeerConnection.instances = [];
  FakePeerConnection.initialGatheringState = "gathering";
  FakePeerConnection.initialSdp = "v=0\r\na=candidate:host 1 udp 1 192.0.2.1 40000 typ host\r\n";
  const htmlPath = path.join(__dirname, "..", "Resources", "door-video.html");
  const html = fs.readFileSync(htmlPath, "utf8");
  const script = html.match(/<script>([\s\S]*)<\/script>/)[1];
  const elements = { v: makeElement(), c: makeElement(), a: makeElement() };
  class FakeDate extends Date {
    constructor(...args) {
      super(...(args.length ? args : [clock.now]));
    }
    static now() { return clock.now; }
  }
  const micTrack = options.micTrack || makeFakeMicTrack();
  const getUserMedia = options.getUserMedia || (async () => makeFakeMicStream(micTrack));
  const context = {
    console: { log() {} },
    Date: FakeDate,
    document: { getElementById: (id) => elements[id] },
    MediaStream: class {},
    RTCPeerConnection: FakePeerConnection,
    navigator: { mediaDevices: { getUserMedia: (constraints) => getUserMedia(constraints) } },
    setTimeout: clock.setTimeout.bind(clock),
    clearTimeout: clock.clearTimeout.bind(clock),
    setInterval: () => 1,
    clearInterval() {},
  };
  context.window = context;
  vm.createContext(context);
  vm.runInContext(script, context, { filename: "Resources/door-video.html" });
  return { context, clock, micTrack };
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

// gateopener-4r7: rule table for the pure iceWaitDecision() function
// exposed by door-video.html. These do not touch FakePeerConnection/clock
// at all -- iceWaitDecision takes only plain booleans/numbers.
function iceWaitDecisionRuleTable(context) {
  const decide = context.iceWaitDecision;
  assert.equal(typeof decide, "function", "iceWaitDecision must be exposed on window for direct testing");

  // Quiet period fires the instant msSinceLastCandidate reaches quietMs
  // (600ms default), given both a host and a srflx/relay candidate.
  assert.equal(decide({
    hasHost: true, hasSrflxOrRelay: true,
    msSinceLastCandidate: 600, msSinceStart: 700, gatheringComplete: false,
  }), "quiet-period");

  // NOT before 600ms -- falls through to "wait".
  assert.equal(decide({
    hasHost: true, hasSrflxOrRelay: true,
    msSinceLastCandidate: 599, msSinceStart: 599, gatheringComplete: false,
  }), "wait");

  // "complete" wins regardless of every other input, including inputs that
  // would otherwise fail every other rule.
  assert.equal(decide({
    hasHost: false, hasSrflxOrRelay: false,
    msSinceLastCandidate: 0, msSinceStart: 0, gatheringComplete: true,
  }), "complete");
  assert.equal(decide({
    hasHost: true, hasSrflxOrRelay: true,
    msSinceLastCandidate: 50, msSinceStart: 50, gatheringComplete: true,
  }), "complete");

  // max-wait fires at exactly maxWaitMs (4000ms default) since start even
  // though msSinceLastCandidate keeps resetting below the 600ms quiet
  // threshold -- simulating a candidate trickling in every 500ms forever.
  assert.equal(decide({
    hasHost: true, hasSrflxOrRelay: true,
    msSinceLastCandidate: 500, msSinceStart: 4000, gatheringComplete: false,
  }), "max-wait-with-candidate");
  // MUTATION CHECK: if the max-wait branch's hasQualifyingPair check were
  // dropped (gating only on msSinceStart), this next case -- max-wait's
  // time threshold met but no srflx/relay yet -- would wrongly return
  // "max-wait-with-candidate" instead of "wait".
  assert.equal(decide({
    hasHost: true, hasSrflxOrRelay: false,
    msSinceLastCandidate: 500, msSinceStart: 4000, gatheringComplete: false,
  }), "wait");

  // No srflx/relay candidate at all: never quiet-period, never max-wait --
  // stays "wait" right up to the old 15s hard deadline, where it hands off
  // to the existing sdpHasQualifyingDeadlineCandidate check (unchanged,
  // gateopener-ndn) by returning "deadline-with-gathered-candidate" as a
  // SIGNAL ONLY (it does not itself guarantee the SDP actually qualifies).
  assert.equal(decide({
    hasHost: true, hasSrflxOrRelay: false,
    msSinceLastCandidate: 14999, msSinceStart: 14999, gatheringComplete: false,
  }), "wait");
  assert.equal(decide({
    hasHost: true, hasSrflxOrRelay: false,
    msSinceLastCandidate: 15000, msSinceStart: 15000, gatheringComplete: false,
  }), "deadline-with-gathered-candidate");

  // host-only (no srflx/relay ever) must never trigger quiet-period or
  // max-wait, even once BOTH of their time thresholds are comfortably
  // exceeded.
  // MUTATION CHECK: dropping the hasSrflxOrRelay requirement from the
  // quiet-period/max-wait conditions (leaving only hasHost) would make this
  // assertion fail, returning "quiet-period" instead of "wait".
  assert.equal(decide({
    hasHost: true, hasSrflxOrRelay: false,
    msSinceLastCandidate: 10000, msSinceStart: 10000, gatheringComplete: false,
  }), "wait");

  // srflx-only (no host candidate) must likewise never trigger quiet-period
  // or max-wait.
  // MUTATION CHECK: dropping the hasHost requirement from the
  // quiet-period/max-wait conditions (leaving only hasSrflxOrRelay) would
  // make this assertion fail, returning "quiet-period" instead of "wait".
  assert.equal(decide({
    hasHost: false, hasSrflxOrRelay: true,
    msSinceLastCandidate: 10000, msSinceStart: 10000, gatheringComplete: false,
  }), "wait");

  // Custom thresholds are honored, not hardcoded, and quiet-period still
  // takes priority over max-wait-with-candidate when both conditions hold.
  assert.equal(decide({
    hasHost: true, hasSrflxOrRelay: true,
    msSinceLastCandidate: 50, msSinceStart: 100, gatheringComplete: false,
    quietMs: 25, maxWaitMs: 90, hardDeadlineMs: 200,
  }), "quiet-period");
  assert.equal(decide({
    hasHost: true, hasSrflxOrRelay: true,
    msSinceLastCandidate: 10, msSinceStart: 90, gatheringComplete: false,
    quietMs: 25, maxWaitMs: 90, hardDeadlineMs: 200,
  }), "max-wait-with-candidate");
}

// Integration test: the quiet-period rule actually resolves
// waitForBoundedIceSnapshot() early (well before the 15s deadline) once a
// host and a srflx candidate have both arrived via pc.onicecandidate and
// ICE_QUIET_PERIOD_MS (600ms) has passed with no new candidate.
async function quietPeriodPublishesEarlyViaOnicecandidateEvents() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  pc.onicecandidate({ candidate: { candidate: "candidate:1 1 udp 2122260223 192.0.2.5 40001 typ host" } });
  pc.onicecandidate({ candidate: { candidate: validCandidate().substring(2) } });

  clock.advance(599);
  assert.equal(context.__state.offerReady, false);
  clock.advance(1); // total 600ms since the last (and only) candidate event
  const sdp = await result;

  assert.equal(sdp, pc.localDescription.sdp);
  assert.equal(context.__state.offerReady, true);
  assert.ok(context.__diag.some((line) =>
    line.includes("ICE wait result: quiet-period after 2 candidates (600ms)")
  ));
  assert.ok(context.__diag.some((line) => line.includes("ICE snapshot published: quiet period")));
  assert.equal(pc.listenerCount(), 0);
  assert.equal(clock.timers.size, 0);
}

// Integration test: max-wait-with-candidate fires at the 4000ms cap even
// though a new qualifying candidate keeps arriving every 500ms (< the
// 600ms quiet period), which would otherwise keep resetting
// msSinceLastCandidate and never let the quiet-period rule fire.
async function maxWaitFiresAtCapDespiteTrickle() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  pc.onicecandidate({ candidate: { candidate: "candidate:1 1 udp 2122260223 192.0.2.5 40001 typ host" } });
  pc.onicecandidate({ candidate: { candidate: validCandidate().substring(2) } });

  for (let elapsed = 500; elapsed < 4000; elapsed += 500) {
    clock.advance(500);
    pc.onicecandidate({
      candidate: { candidate: validCandidate("relay", "198.51.100." + (elapsed / 500)).substring(2) },
    });
  }
  assert.equal(context.__state.offerReady, false);
  clock.advance(500); // total 4000ms since start
  const sdp = await result;

  assert.equal(sdp, pc.localDescription.sdp);
  assert.equal(context.__state.offerReady, true);
  assert.ok(context.__diag.some((line) =>
    line.includes("ICE wait result: max-wait-with-candidate after 9 candidates (4000ms)")
  ));
  assert.ok(context.__diag.some((line) => line.includes("ICE snapshot published: max wait with candidate")));
  assert.equal(pc.listenerCount(), 0);
  assert.equal(clock.timers.size, 0);
}

// bead gateopener-1pm.3: call mode builds audio(sendrecv, with mic
// track)/video(recvonly)/datachannel, in that order -- the m-line ORDER
// never changes, only the audio transceiver's direction/track.
async function callModeTransceiverOrderIsAudioSendrecvVideoRecvonlyDatachannel() {
  const { context, micTrack } = loadPage();
  FakePeerConnection.initialGatheringState = "complete";
  context.__CALL_MODE__ = true;
  const result = context.startNegotiation();
  for (let i = 0; i < 5; i++) await Promise.resolve();
  const pc = FakePeerConnection.instances[0];
  const sdp = await result;

  assert.equal(sdp, pc.localDescription.sdp);
  assert.equal(context.__state.offerReady, true);
  assert.equal(pc.transceivers.length, 3);
  assert.equal(pc.transceivers[0].kind, "audio");
  assert.equal(pc.transceivers[0].direction, "sendrecv");
  assert.equal(pc.transceivers[0].track, micTrack);
  assert.equal(pc.transceivers[1].kind, "video");
  assert.equal(pc.transceivers[1].direction, "recvonly");
  assert.equal(pc.transceivers[2].kind, "datachannel");
  assert.ok(context.__diag.some((line) => line.includes("mic: label=Fake Mic")));
}

// bead gateopener-1pm.3: view mode (the default -- __CALL_MODE__ left unset,
// matching production) must be byte-for-byte unchanged: audio(recvonly, no
// track)/video(recvonly)/datachannel.
// MUTATION CHECK: swapping the addTransceiver('audio', ...)/addTransceiver
// ('video', ...) call order in door-video.html would make transceivers[0]
// report kind "video" here and fail this assertion.
async function viewModeTransceiverOrderUnchangedAudioRecvonlyVideoRecvonlyDatachannel() {
  const { context } = loadPage();
  FakePeerConnection.initialGatheringState = "complete";
  const result = context.startNegotiation();
  for (let i = 0; i < 5; i++) await Promise.resolve();
  const pc = FakePeerConnection.instances[0];
  await result;

  assert.equal(pc.transceivers.length, 3);
  assert.equal(pc.transceivers[0].kind, "audio");
  assert.equal(pc.transceivers[0].direction, "recvonly");
  assert.equal(pc.transceivers[0].track, null);
  assert.equal(pc.transceivers[1].kind, "video");
  assert.equal(pc.transceivers[1].direction, "recvonly");
  assert.equal(pc.transceivers[2].kind, "datachannel");
}

// bead gateopener-1pm.3: a getUserMedia rejection must reject
// startNegotiation() with an error whose message starts with "mic:" (so
// Swift, bead 1pm.4, can map it), diag the failure, and produce NO
// RTCPeerConnection/offer at all.
async function micRejectionFailsBeforeOfferWithMicPrefixedError() {
  const { context } = loadPage({
    getUserMedia: async () => {
      const error = new Error("The request is not allowed");
      error.name = "NotAllowedError";
      throw error;
    },
  });
  context.__CALL_MODE__ = true;
  const result = context.startNegotiation();
  for (let i = 0; i < 5; i++) await Promise.resolve();

  assert.equal(FakePeerConnection.instances.length, 0, "no RTCPeerConnection should be created on mic failure");
  try {
    await result;
    assert.fail("expected startNegotiation to reject");
  } catch (error) {
    assert.ok(
      error.message.startsWith("mic:"),
      "error message must start with 'mic:'; got: " + error.message
    );
  }
  assert.equal(context.__state.offerReady, false);
  assert.equal(context.__state.offerSdp, null);
  assert.ok(context.__diag.some((line) => line.includes("mic: error:NotAllowedError")));
}

// bead gateopener-1pm.3: the answer-audio diagnostic parser, exercised
// against the m=audio block copied verbatim from
// ../comelit/docs/viewdoor-capture-2026-09-27/official-1-answer.sdp (the
// official app's on-demand answer -- door answers sendrecv PCMA/8000).
const OFFICIAL_ANSWER_AUDIO_MSECTION = [
  "m=audio 51735 UDP/TLS/RTP/SAVPF 8",
  "c=IN IP4 95.179.217.134",
  "a=sendrecv",
  "a=mid:0",
  "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level",
  "a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
  "a=extmap:3 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01",
  "a=extmap:4 urn:ietf:params:rtp-hdrext:sdes:mid",
  "a=rtcp-mux",
  "a=rtpmap:8 PCMA/8000",
  "a=candidate:Sc0a80183 1 UDP 1694498815 194.125.119.226 33310 typ srflx raddr 192.168.1.131 rport 33310",
  "a=ice-ufrag:5de10233",
  "a=ice-pwd:3a51216e4dbeb075750de716",
  "a=fingerprint:sha-256 D7:03:55:98:0C:26:0A:46:4D:2B:04:E3:48:99:FC:0E:B4:07:18:AA:5D:8B:C6:18:EE:72:99:2B:D6:CD:F2:CD",
  "a=setup:active",
  "a=ssrc:530695621 cname:user361341566@host-516328566",
].join("\r\n");

async function answerAudioDiagParsesSendrecvPcmaFromCaptureSample() {
  const { context } = loadPage();
  FakePeerConnection.initialGatheringState = "complete";
  context.__CALL_MODE__ = true;
  const result = context.startNegotiation();
  for (let i = 0; i < 5; i++) await Promise.resolve();
  await result;

  const answerSdp = "v=0\r\na=group:BUNDLE 0\r\n" + OFFICIAL_ANSWER_AUDIO_MSECTION + "\r\n";
  await context.applyAnswer(answerSdp);

  assert.ok(context.__diag.some((line) => line.includes("answer audio: sendrecv PCMA")));
}

const HOST_LINE = "candidate:1 1 udp 2122260223 192.0.2.5 40001 typ host";

async function hostOnlyFor3sRejectsIceNoReflexive() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  const settled = result.then(() => null, (e) => e);
  pc.onicecandidate({ candidate: { candidate: HOST_LINE } });
  clock.advance(2900);
  assert.equal(context.__diag.some((l) => l.includes("stun blocked")), false);
  clock.advance(100);
  const error = await settled;
  assert.ok(error, "expected rejection at 3s");
  assert.equal(error.code, "ice-no-reflexive");
  assert.equal(error.name, "DoorVideoNegotiationError");
  assert.ok(context.__diag.some((l) => l.includes("stun blocked: no reflexive candidate after 3s")));
  assert.equal(context.__state.offerReady, false);
  assert.equal(pc.listenerCount(), 0);
  assert.equal(clock.timers.size, 0);
}

async function srflxAtOneSecondDoesNotRejectAndPublishesNormally() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  pc.onicecandidate({ candidate: { candidate: HOST_LINE } });
  clock.advance(1000);
  pc.onicecandidate({ candidate: { candidate: validCandidate().substring(2) } });
  clock.advance(600); // quiet period
  const sdp = await result;
  assert.equal(sdp, pc.localDescription.sdp);
  assert.equal(context.__state.offerReady, true);
  assert.equal(context.__diag.some((l) => l.includes("stun blocked")), false);
  assert.equal(clock.timers.size, 0);
}

async function zeroCandidatesAt3sDoesNotRejectEarly() {
  const { context, clock } = loadPage();
  const { result, pc } = await beginNegotiation(context);
  const settled = result.then(() => "resolved", (e) => e);
  clock.advance(5000);
  await Promise.resolve();
  assert.equal(context.__diag.some((l) => l.includes("stun blocked")), false);
  clock.advance(10000); // existing 15s deadline path
  const outcome = await settled;
  assert.equal(outcome.code, "ice-gathering-timeout");
}

// A test awaiting a promise that never settles would otherwise let node exit 0
// silently; fail loudly instead.
let completed = false;
process.on("exit", () => {
  if (!completed && !process.exitCode) {
    console.error("door-video negotiation tests did not run to completion");
    process.exitCode = 1;
  }
});

(async () => {
  await hostOnlyFor3sRejectsIceNoReflexive();
  await srflxAtOneSecondDoesNotRejectAndPublishesNormally();
  await zeroCandidatesAt3sDoesNotRejectEarly();
  iceWaitDecisionRuleTable(loadPage().context);
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
  await quietPeriodPublishesEarlyViaOnicecandidateEvents();
  await maxWaitFiresAtCapDespiteTrickle();
  await callModeTransceiverOrderIsAudioSendrecvVideoRecvonlyDatachannel();
  await viewModeTransceiverOrderUnchangedAudioRecvonlyVideoRecvonlyDatachannel();
  await micRejectionFailsBeforeOfferWithMicPrefixedError();
  await answerAudioDiagParsesSendrecvPcmaFromCaptureSample();
  completed = true;
  console.log("door-video negotiation tests passed");
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
