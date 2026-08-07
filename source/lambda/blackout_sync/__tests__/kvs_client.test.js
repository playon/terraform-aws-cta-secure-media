const { test } = require("node:test");
const assert = require("node:assert/strict");
const { diff, KEY_PREFIX } = require("../kvs_client");

test("diff: empty everything = no ops", () => {
    const { puts, deletes } = diff(new Set(), new Map(), new Set());
    assert.equal(puts.length, 0);
    assert.equal(deletes.length, 0);
});

test("diff: new broadcasts produce puts", () => {
    const desired = new Map([["abc", "512,523"], ["def", "819"]]);
    const inScan = new Set(["abc", "def"]);
    const { puts, deletes } = diff(new Set(), desired, inScan);
    assert.equal(puts.length, 2);
    assert.deepEqual(puts[0], { Key: KEY_PREFIX + "abc", Value: "512,523" });
    assert.deepEqual(puts[1], { Key: KEY_PREFIX + "def", Value: "819" });
    assert.equal(deletes.length, 0);
});

test("diff: broadcast in-scan with DMAs cleared → delete", () => {
    const existing = new Set([KEY_PREFIX + "abc"]);
    const desired = new Map(); // abc no longer has DMAs
    const inScan = new Set(["abc"]); // but we DID see abc in the scan
    const { puts, deletes } = diff(existing, desired, inScan);
    assert.equal(puts.length, 0);
    assert.equal(deletes.length, 1);
    assert.deepEqual(deletes[0], { Key: KEY_PREFIX + "abc" });
});

test("diff: broadcast OUT of scan window is left alone (no delete)", () => {
    const existing = new Set([KEY_PREFIX + "aged_out"]);
    const desired = new Map();
    const inScan = new Set(); // broadcast is not in this tick's window
    const { puts, deletes } = diff(existing, desired, inScan);
    assert.equal(puts.length, 0);
    assert.equal(deletes.length, 0, "should NOT delete broadcasts outside the scan window");
});

test("diff: mixed — some in-scan cleared, some out-of-window", () => {
    const existing = new Set([
        KEY_PREFIX + "abc",         // in-scan, has DMAs → put
        KEY_PREFIX + "def",         // in-scan, DMAs cleared → delete
        KEY_PREFIX + "old_broadcast" // out of scan → leave
    ]);
    const desired = new Map([["abc", "512"]]);
    const inScan = new Set(["abc", "def"]);
    const { puts, deletes } = diff(existing, desired, inScan);
    assert.equal(puts.length, 1);
    assert.deepEqual(puts[0], { Key: KEY_PREFIX + "abc", Value: "512" });
    assert.equal(deletes.length, 1);
    assert.deepEqual(deletes[0], { Key: KEY_PREFIX + "def" });
});

test("diff: changed value produces put (idempotent overwrite)", () => {
    const existing = new Set([KEY_PREFIX + "abc"]);
    const desired = new Map([["abc", "999"]]);
    const inScan = new Set(["abc"]);
    const { puts, deletes } = diff(existing, desired, inScan);
    assert.equal(puts.length, 1);
    assert.equal(deletes.length, 0);
    assert.equal(puts[0].Value, "999");
});

test("diff: unchanged existing still emits a put (Update is upsert; cheap)", () => {
    const existing = new Set([KEY_PREFIX + "abc"]);
    const desired = new Map([["abc", "512"]]);
    const inScan = new Set(["abc"]);
    const { puts, deletes } = diff(existing, desired, inScan);
    assert.equal(puts.length, 1);
    assert.equal(deletes.length, 0);
});

test("diff: ignores non-blackout keys already in KVS (e.g. key:default)", () => {
    const existing = new Set(["key:default", "revoked:xyz", KEY_PREFIX + "abc"]);
    const desired = new Map();
    const inScan = new Set(["abc"]);
    const { puts, deletes } = diff(existing, desired, inScan);
    assert.equal(puts.length, 0);
    assert.equal(deletes.length, 1);
    assert.deepEqual(deletes[0], { Key: KEY_PREFIX + "abc" });
});
