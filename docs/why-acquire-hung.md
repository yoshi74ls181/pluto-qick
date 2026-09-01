# Why acquire_decimated() hung, and what was ruled out

`acquire_decimated()` blocked forever on the first hardware attempt. The polling
loop is:

    soc.start_tproc()
    while count < total_count:
        count = soc.get_tproc_counter(addr=self.counter_addr)

so it terminates only when the tProc completes a shot. Three things could stop
that, and it is worth recording which one it was, because two of them were
plausible enough to chase.

## Correction: this document was written before the cause was fully understood

The section below is right that the cores were not enabled, but the fix it
describes -- issuing `TIME_UPDATE` and `CORE_START` -- turned out not to be
sufficient, and the reason is worth recording.

`acquire()` calls `clear_tproc_counter()` immediately before starting, which on
tProc v2 means `PROCESSOR_RESET`. After a reset this firmware responds only to
`PROCESSOR_RUN`; `time_reset`, `time_update`, `core_start` and `start` all leave
the status register untouched. Worse, the handshake **swallows the first control
write after a reset**, and whether any given write takes is timing dependent: the
same sequence that brought both cores up in one run left `Core_EN=0` in the next.

So `QickSocE200.start_tproc()` now issues `run()`, pauses, delegates upward, and
then **verifies** the status, retrying up to twelve times and raising with the
register value if the cores never come up. Issuing commands blind is not reliable
on this build.

A second, entirely separate cause was hiding behind the first: even with the
cores running, nothing was transmitted, because the AD9361 only forwards fabric
data when its transmit channel is in DMA mode. See `loopback.md`.

## The original diagnosis: the cores were never enabled

`QickSoc.start_tproc()` issues only `PROCESSOR_START` (`tproc_ctrl` bit 2). After
a program is loaded, the status register reported:

    Core_STATE = C_STOP   Core_EN = 0   Time_EN = 0     time_usr frozen at 0

Nothing in QICK's Python ever calls `core_start()`, so on the firmware their
projects ship the cores must come up enabled. They do not here. Issuing
`TIME_UPDATE` then `CORE_START` fixes it, and `QickSocE200.start_tproc()` now
does so before delegating upward. It has to happen there rather than once at load
time, because `start_src()` calls `stop()` immediately beforehand.

That also produced the cleanest available confirmation that the clocking work is
right: once enabled, `time_usr` advances 6.16e6 ticks per 200 ms, i.e. 30.8 MHz,
matching the 30.72 MHz AD9361 sample clock.

## Ruled out: the program never reaching the counter

`AveragerProgramV2.make_program()` emits

    set_ext_counter(addr=1)  ->  open_loop(reps)  ->  _body()  ->
    wait_auto / delay_auto   ->  inc_ext_counter(addr=1)  ->  close_loop()  ->  end()

so the increment sits inside the reps loop and is reached on every shot. With
`reps=1` the counter reaches 1 and the poll exits. Nothing in the program
structure can prevent completion.

## Ruled out: wait_auto blocking on the readout

`wait_auto(ros=True)` sits between the body and the counter increment, so a
handshake-based wait on a readout-done signal this design does not wire would
hang exactly where observed. It is not handshake based: `Wait.preprocess()`
computes `max_t` from compile-time timestamps of the declared pulses and readout
windows and emits an absolute-time `WAIT`. The tProc's timing core advances on
`t_clk`, which is measured running, so the instruction always expires.

## Ruled out earlier: a dead datapath clock

Worth noting because it was the first hypothesis and it was wrong in an
instructive way. Reading the buffer with `outsel='dds'` -- a path internal to the
readout, needing no ADC data -- returned zeros, which looked like an unclocked
datapath. It was not: the buffer only captures on a trigger, and the diagnostic
never triggered it. Zeros were the correct answer to the wrong question.
