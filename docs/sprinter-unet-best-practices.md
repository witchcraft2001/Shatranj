# UNET interrupt safety and timing

This guide is for Sprinter applications using UNET through libman. Call the
library from the main loop, with interrupts enabled and one owner of the network
state. An interrupt handler should only schedule work or consume application
data prepared beforehand. The current API provides neither an ISR-safe calling
contract nor a worst-case execution time in CPU cycles.

The scope is the dependency set shipped by Shatranj: UNETESP 0.3.1, UNETRTL
0.3.10 and UNET509B 0.1.2, recorded with SHA-256 hashes in the
[DLL manifest](../extern/unet_libs_asm/extern/core/dll/manifest.json).
The core revision is `8566311a53ed17f4f703d48b6aa3ec40256558a7`; libman is
`d392c938d3235a8c6db09a5421c674631dfa1f23`. Recheck timing assumptions when
changing either dependency. There are no hardware timing measurements attached
to this guide.

## Calling from an interrupt handler

Do not call UNET, UNETLD or libman from an ISR, including a timer ISR. This is
the integration policy supported by the inspected code. A dedicated interrupt-only
caller would need a separate audit of DSS, memory mapping, interrupt
state, stack use and every selected DLL path; the existing ABI supplies no such
guarantee.

There are several independent reasons:

- **UNET is not reentrant.** An ISR can interrupt an existing operation and
  overwrite its parser, connection or transfer state. The restriction also
  applies across channels of one DLL.
- **The libman dispatcher has shared mutable state.** `_L_CALL` writes
  `lcstart`, `lc_fun`, `lcoldp` and the saved-page operand at `lc4_+1`. Calling
  another DLL through the same libman instance from an ISR can corrupt an
  interrupted dispatch too. A guard around only one UNET function is inadequate.
- **Calls change memory mappings and enter DSS.** The dispatcher uses DSS
  `SETWINn`; backends also map hardware and may use extra code pages. An ISR
  cannot assume the application's ordinary page layout while a call is active.
- **Interrupt state is not an ISR entry contract.** Shatranj's gateway explicitly
  executes `EI` before dispatch. Calling that gateway from an ISR can enable
  nested interrupts. Disabling interrupts around an entire network call is also
  unsuitable: a stalled operation can delay timer, keyboard and audio service
  for a long time.
- **Operation duration depends on input and hardware.** Even a receive poll can
  parse packets, copy data and perform protocol work. A short timeout does not
  establish a cycle budget.

Keep the interrupt vector, handler, its data and the active stack in memory
that remains mapped throughout the call. Preserve all registers the handler
uses, including index or alternate registers when applicable. In Shatranj the
network gateway and IM2 support occupy permanent WIN2 memory, while UNET is
loaded into WIN1. ISR code must not enter the DLL gateway or the shared libman.

For an ISR that needs connection status, publish a small application-owned
snapshot from the main loop. Do not call `STATUS` in the handler merely because
its backend work is cheap: the shared dispatcher is still involved. Use a
short critical section or a consistent snapshot protocol for multi-byte data.

## What the timing parameters mean

UNET operations execute synchronously on the calling Z80. The implementations
poll hardware rather than installing a background network ISR. ESP performs
TCP/IP on the module; RTL and 509B run their software stack on the Z80. Between
calls the DLL executes no Z80 code, although the module or NIC can receive and
buffer traffic.

| Operation | Timing expectation | Scheduling rule |
| --- | --- | --- |
| `GETCAPS`, channel `STATUS` | Small state queries, with dispatcher overhead; no published cycle bound | Cache results needed by an ISR |
| `RECV`, `IY=0` | Poll mode; work varies between idle, buffered data and protocol processing | Use from the main loop with a limited buffer and call count |
| `RECV`, `IY>0` | May wait according to the backend timeout implementation | Use only where the application can tolerate the wait |
| `SEND`, default mode | May wait for transport progress or failure | Treat as potentially blocking |
| `SEND` with `SENDSLICE` | Can yield `NERR_AGAIN`; no general whole-call deadline | Resume cooperatively from the main loop |
| Connect, resolve, ping, close and network initialization | Hardware, network responses and retries affect duration | Run in explicit connection or shutdown states |
| DLL selection, loading and unloading | May involve DSS environment, disk, allocation and lifecycle calls | Keep outside time-critical processing |

For shipped ESP 0.3.1, `RECV(IY=0)` still performs an initial UART spin and
internally clamps its timeout to one millisecond. This does **not** mean the
complete call takes at most one millisecond. The
[API reference](../extern/unet_libs_asm/extern/core/docs/UNETAPI.md) also documents
a five-second per-byte wait inside ESP binary frame capture. Buffer length
limits returned data; it is not a universal limit on internal protocol work.

`SENDSLICE` requires `CAP_ASYNCSEND` and a successful `SETOPT`. Zero selects
blocking mode; nonzero values are clamped to at least 50 ms. In particular,
the ESP slice measures **link silence**. Continued input can postpone yielding,
and a partial binary frame has its own wait rules. A 50 ms slice cannot promise
a 20 ms frame budget. Likewise, the ESP firmware's configured four-second
send timeout and the DLL's five-second wait are individual timeout settings,
not a bound on a complete operation with all parsing and recovery included.

Distinguish three quantities when budgeting:

1. **Elapsed call time:** entry to return, including interrupts serviced during
   the call. This determines how long main-loop work is delayed.
2. **CPU work:** instructions executed by the gateway, dispatcher and backend,
   including polling loops. Waiting by polling still occupies the CPU.
3. **Longest interval with interrupts disabled:** this determines interrupt
   latency. Returning with interrupts enabled does not bound that interval.

At a nominal 21 MHz, 1 ms corresponds to 21,000 clock cycles and a 20 ms frame
to 420,000. These are unit conversions, not UNET measurements. Actual execution
depends on instruction paths, memory and ISA waits, interrupt load and hardware.
Counting instructions in a short DLL entry point alone excludes libman, DSS and
the hardware access path. A published maximum would require auditing the entire
path and all bounded loops for the exact binary and machine configuration.

## Main loop integration

Use one network owner for all channels and all lifecycle operations. Keep a
loaded DLL across ordinary frame updates. Select, load, check ABI and required
capabilities, and start the network through UNETLD; release an existing handle
before retrying a failed load sequence, as specified by
[UNETLD](../extern/unet_libs_asm/docs/UNETLD.md).

A suitable scheduler has this shape (pseudocode):

```text
timer ISR:
    mark network work due
    service only bounded interrupt work
    return

main loop:
    process input and update the application
    atomically take and clear the network-due flag
    if network work was due:
        poll receive with IY = 0 and a small buffer
        make only a limited number of additional calls if data is pending
        advance at most one scheduled send or connection step
    render when needed
```

The due flag may coalesce ticks; it is a scheduling hint, not an elapsed-time
counter. Clear it atomically before doing the work so a tick during a network
call remains pending. If every event matters, use a bounded queue or counter
with explicit overflow handling instead. Keep critical sections limited to
shared-state updates; never hold them around the DLL call.

Bound both calls and bytes per main-loop iteration, and yield to application
work between batches. Shatranj currently requests at most 255 bytes per receive
call and makes at most two polls per pump; the second requires `RXF_MORE`.
These bounds prevent an application-level drain loop from running forever,
but they do not bound the time inside one call. Poll often enough for the
traffic and hardware buffers; `STATUS` does not replace servicing `RECV`.

For cooperative sending, check `CAP_ASYNCSEND`, set `SENDSLICE`, and keep the
same channel, buffer address, length and payload until the transaction completes.
On `NERR_AGAIN`, resume the **same** send; do not advance the pointer by `DE` or
submit its suffix as a new transaction. Between resumes the documented ESP
contract permits `RECV` and `STATUS`; while the send is suspended, ESP receive
serves buffered data only. Finish the send before normal close or unload. A
stuck transaction needs an explicit recovery policy; do not use an ISR to free
the DLL or jump out of a live call. Shatranj currently uses default blocking
send mode, so this is guidance for a future scheduler change.

Inspect both result layers: CF reports a dispatcher failure, while A reports
the UNET status after successful dispatch. Respect returned byte counts and
`RXF_MORE`, `RXF_LOST` and `NERR_CLOSED`; transport success alone does not prove
application-level delivery. Preserve buffers and DLL state in stable memory.
As required by the ABI, all argument buffers must be wholly below `0xC000`
and outside the DLL's mapped 16 KiB window. Account for any additional mapping
performed by the chosen backend when placing the stack and ISR state.

## Establishing a timing budget

Before committing to an audio, raster or frame deadline, measure the exact DLL
hashes on the target hardware. Record DSS and firmware versions, CPU clock,
UART baud rate or card configuration, traffic pattern and interrupt workload.
Measure the complete application gateway entry to return, and separately the
longest interrupt-disabled interval. Use a suitable hardware timer or logic
analyzer; a 50 Hz frame counter cannot resolve short calls or critical sections.
An emulator trace can help count paths, but hardware wait behavior still needs
validation on the machine.

Exercise idle receive, buffered receive, maximum requested payload, simultaneous
traffic, irrelevant incoming packets, partial or stalled input, send without
acknowledgement, DNS/ARP failure, peer close, cancellation and reconnect. For
each backend and operation, report typical time, a percentile such as p99,
observed maximum and maximum interrupt latency. Label an observed maximum as a
measurement, not a proven worst-case bound. Hardware measurements remain pending.

If a strict cycle budget is a requirement, the current API is insufficient.
A suitable extension would need a bounded `STEP`/`POLL` contract limiting both
work and waiting, incremental connect/send/receive state, bounded critical
sections, and a defined continuation result. Such an extension would still run
from the main loop unless it separately guaranteed ISR safety across the
dispatcher, DSS and backend. An outer deadline checked after a call cannot
preempt a blocking operation already in progress.

## Source evidence

- [UNET API](../extern/unet_libs_asm/extern/core/docs/UNETAPI.md): non-reentrancy,
  buffer placement, receive timeouts and suspended-send semantics.
- [libman dispatcher](../extern/libman/libman/libman_core13.asm): `_L_CALL`,
  shared dispatch state, DSS window mapping and return-page restoration.
- [Shatranj network gateway](../asm/sprinter/net_gate.asm): reentry guard,
  explicit `EI`, resident staging buffers and `RECV(IY=0)` wrapper.
- [Shatranj IM2 support](../asm/sprinter/im2_s1.asm): permanent interrupt state
  and constraints on remapping memory while interrupts are enabled.
- [Shatranj receive pump](../src/sprinter/transport/net_frame.c): bounded poll
  count, receive capacity and result handling.
