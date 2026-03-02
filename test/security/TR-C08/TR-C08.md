# TR-C08 -- setReadChannel(_active=false) Orphans In-Flight GUIDs

**Severity:** Medium
**Status:** Open
**Location:** `src/cross-chain/layerZero/LzAdapter.sol` -- `setReadChannel()` (line 184-187)

---

## The bug

`setReadChannel(uint32 _channelId, bool _active)` unconditionally assigns `READ_CHANNEL = _channelId` regardless of the `_active` flag. When called with `_active=false` to deactivate a channel, the function correctly zeroes the peer (`_setPeer(_channelId, bytes32(0))`), but it also silently moves the `READ_CHANNEL` pointer to the now-deactivated channel. Any subsequent call to `initiateCrossChainAccounting` sends its LZ read request on that channel — which has no peer set — so LayerZero cannot deliver the response. All GUIDs registered in `_guidToCallInfo` for accounting cycles sent after the pointer shift are permanently orphaned.

---

## Root cause

`LzAdapter.sol` lines 184-187:

```solidity
function setReadChannel(uint32 _channelId, bool _active) public override(IBridgeAdapter, OAppRead) onlyOwner {
    _setPeer(_channelId, _active ? AddressCast.toBytes32(address(this)) : bytes32(0));
    READ_CHANNEL = _channelId;   // ← no guard for _active
}
```

`READ_CHANNEL = _channelId` executes unconditionally. When `_active=false`, the peer for `_channelId` is set to `bytes32(0)`, but `READ_CHANNEL` still advances to `_channelId`. `initiateCrossChainAccounting` always sends on `READ_CHANNEL`:

```solidity
receipt = _lzSend(
    READ_CHANNEL,   // ← uses whatever READ_CHANNEL is at call time
    cmd, ...
);
_guidToCallInfo[receipt.guid] = CallInfo({vault: msg.sender, initiator: _initiator});
```

LayerZero verifies the peer for the channel before calling `_lzReceive`. With `peer[READ_CHANNEL] = bytes32(0)`, LayerZero will not deliver any response, and `_lzReceive` is never invoked. The GUID entry in `_guidToCallInfo` is never cleaned up, and the vault's accounting remains frozen.

---

## Entry conditions

The bug requires the contract owner to call `setReadChannel` with `_active=false`. Three distinct scenarios activate it:

**Scenario A -- Accidental pointer shift:**
Owner calls `setReadChannel(CHAN_B, false)` intending to deactivate a channel that was already inactive. The intended effect is a no-op on peer state. Actual effect: `READ_CHANNEL` moves from `CHAN_A` to `CHAN_B`. Future accounting requests are sent on `CHAN_B` (peer=0), permanently orphaning all future GUIDs from that point.

**Scenario B -- Channel migration then cleanup (most likely in practice):**
Owner migrates to a new channel via `setReadChannel(CHAN_B, true)` (correct -- `READ_CHANNEL = CHAN_B`). Then calls `setReadChannel(CHAN_A, false)` to deactivate the old channel. Bug: `READ_CHANNEL` reverts from `CHAN_B` back to `CHAN_A`. `peer[CHAN_A] = bytes32(0)` after this call. All future sends use the now-deactivated `CHAN_A`. Any in-flight GUIDs sent on `CHAN_A` before the migration are also orphaned because the peer check fails.

**Scenario C -- Self-deactivation of active channel:**
Owner calls `setReadChannel(CHAN_A, false)` on the currently active channel. `peer[CHAN_A] = bytes32(0)`. `READ_CHANNEL` remains `CHAN_A` (pointer unchanged). All in-flight GUIDs on `CHAN_A` are orphaned (peer check fails). All future sends also fail for the same reason.

No deployed vault is currently affected. The bug is dormant unless an operator performs a channel management operation with `_active=false`.

---

## Impact

**Accounting freeze:** `_guidToCallInfo` entries for orphaned GUIDs are never deleted. The vault's `updateAccountingInfoForRequest` is never called for those GUIDs. Share pricing remains at the stale accounting value until a new successful accounting cycle, which cannot occur while `READ_CHANNEL` points to a channel with no peer.

**Token lockup:** `_lzReceive` is the only code path that calls `refundRequestTokens`. If the LZ response is never delivered, tokens locked in the vault for an in-flight accounting request (native gas, ERC20 deposits) are never refunded to the initiator. Funds are soft-locked until the next accounting cycle succeeds.

**Irrecoverability:** There is no on-chain function to cancel or flush a specific GUID from `_guidToCallInfo`. Recovery requires the owner to call `setReadChannel` with a correctly configured channel and re-run `initiateCrossChainAccounting` for each affected vault. Existing orphaned GUIDs cannot be processed unless LayerZero eventually re-delivers to a re-activated peer — which is not guaranteed.

**Scope:** The bug only affects vaults that use cross-chain accounting (hub vaults with spokes). Single-chain vaults and pure bridging operations are unaffected.

---

## Precedent

**Hop Protocol bridge (2022):** Hop's `L2_AmmWrapper.sol` contained a state pointer that was updated in both the activation and deactivation branches of a conditional, rather than only in the activation branch. A migration from AMM-A to AMM-B followed by cleanup of AMM-A moved the internal router pointer back to AMM-A (deactivated). Subsequent swaps routed through the stale pointer reverted, stranding in-flight bridge transactions that had already locked funds on L1. Root cause: pointer updated unconditionally in both branches.

**Applicability to MORE vaults:** The same architectural error appears here. `READ_CHANNEL` is the pointer that controls where cross-chain read requests are sent. Updating it in the deactivation branch as well as the activation branch allows a routine channel cleanup operation to silently redirect all future accounting traffic to a channel with no peer -- the same class of bug that stranded Hop bridge funds, but applied to LayerZero read channel management.

---

## Fix

Guard the `READ_CHANNEL` assignment to execute only when activating:

```diff
 function setReadChannel(uint32 _channelId, bool _active) public override(IBridgeAdapter, OAppRead) onlyOwner {
     _setPeer(_channelId, _active ? AddressCast.toBytes32(address(this)) : bytes32(0));
-    READ_CHANNEL = _channelId;
+    if (_active) { READ_CHANNEL = _channelId; }
 }
```

**Effect on all three scenarios:**
- Scenario A: `setReadChannel(CHAN_B, false)` leaves `READ_CHANNEL = CHAN_A`. No pointer shift. Future accounting continues on CHAN_A.
- Scenario B: After `setReadChannel(CHAN_B, true)` then `setReadChannel(CHAN_A, false)`, `READ_CHANNEL` stays `CHAN_B`. Old channel cleaned up correctly.
- Scenario C: `setReadChannel(CHAN_A, false)` leaves `READ_CHANNEL = CHAN_A` but removes the peer. The channel is deactivated. If the operator then activates a different channel, `READ_CHANNEL` will advance correctly on the `_active=true` call.

**No regression:** The existing `test_setReadChannel_success` test (activating a new channel) continues to pass because `_active=true` still updates `READ_CHANNEL`.

---

## Bytecode

- Remove 1 unconditional `SSTORE` for `READ_CHANNEL`
- Add 1 `JUMPI` + conditional `SSTORE`
- Net: approximately **+4 bytes** deployed bytecode in `LzAdapter`

---

## Tests

| File | Test | Status (unfixed) | What it proves |
|------|------|-----------------|----------------|
| `TR-C08-SetReadChannelOrphans.t.sol` | `test_C08_01_setReadChannel_false_changes_READ_CHANNEL` | PASS | BUG: READ_CHANNEL moves from CHAN_A to CHAN_B on deactivation call |
| `TR-C08-SetReadChannelOrphans.t.sol` | `test_C08_02_channel_migration_then_deactivation_reverts_READ_CHANNEL` | PASS | BUG: migration+cleanup reverts READ_CHANNEL from new to old channel |
| `TR-C08-SetReadChannelOrphans.t.sol` | `test_C08_03_self_deactivation_orphans_inflight_GUIDs` | PASS | BUG: self-deactivation removes peer, in-flight GUIDs stranded |
| `TR-C08-SetReadChannelOrphans.t.sol` | `test_C08_FIX_setReadChannel_false_preserves_READ_CHANNEL` | FAIL (expected) | Fix verification: READ_CHANNEL unchanged after deactivation call |
