# axi4-lite-uvm-verification
"UVM verification environment for an AXI4-Lite slave: 100% functional coverage”.
AXI4-Lite Register Slave: UVM Verification
A UVM 1.2 verification environment for a small AXI4-Lite register slave, written in SystemVerilog.
It combines a driver/monitor/sequencer agent, a scoreboard with a reference model, SystemVerilog
protocol assertions, and functional coverage driven by directed and constrained-random sequences.
Result (Synopsys VCS X-2025.06-SP1, UVM 1.2, via EDA Playground)
Item	Result
Scoreboard	526 writes and 497 reads checked, 0 mismatches
Functional coverage	100.00 % (10 coverpoints, 2 crosses)
UVM errors / fatals	0 / 0
Assertions	7 protocol assertions, no failures
Cover properties	4 of 4 hit (SLVERR write 78, SLVERR read 80, B back-pressure 609, R back-pressure 1027)
Simulated time	about 69.9 us
The raw log lines are in `results/vcs_run_summary.txt`. That run used the
previous revision of `testbench.sv`, which printed one overall coverage line. The current revision runs
the same stimulus and additionally prints coverage for every coverpoint and cross.
DUT (`design.sv`)
`axi_lite_slave`: 4 x 32-bit registers at word addresses 0x00 to 0x0C.
Byte-lane writes through `WSTRB`; a write with no strobe set leaves the register unchanged.
`OKAY` (2'b00) for addresses inside the register file, `SLVERR` (2'b10) outside it.
One outstanding write and one outstanding read at a time; AW and W may arrive in either order.
`axi_lite_if` holds the signals, the driver and monitor clocking blocks, the assertions and the cover properties.
Verification environment (`testbench.sv`)
```
 sequences (directed + constrained random)
        |
   sequencer -> driver ---------------> axi_lite_if ---------> DUT
                  |                         |
                  | completed items         | observed handshakes
                  v                         v
             coverage collector          monitor -> scoreboard (reference model)
```
Sequence item: read/write, address, data, `WSTRB`, and random delays for AW, W, BREADY, AR and RREADY.
Directed sequence: write/read-back of every register, each byte lane on its own, a write with no strobes,
and out-of-range accesses.
Random sequence: 1000 transactions by default, about 85 % in-range and 15 % out-of-range addresses, mixed
strobe patterns. Run `+NUM_TXN=5000` for more.
Monitor: rebuilds transactions only from observed handshakes, independent of the driver.
Scoreboard: models the 4 registers, including byte strobes, and checks every response code and every read value.
Assertions and cover properties (in `axi_lite_if`)
AW payload stable until `AWREADY`
W payload stable until `WREADY`
AR payload stable until `ARREADY`
B channel stable until `BREADY`
R channel stable until `RREADY`
`BRESP` never EXOKAY
`RRESP` never EXOKAY
Cover properties: SLVERR on write, SLVERR on read, B-channel back-pressure, R-channel back-pressure.
Functional coverage
Coverpoints: operation, register address (4 registers plus out-of-range), response code, byte-strobe pattern
(none, single, two, three, all lanes), AW delay, W delay, B-ready delay, AR delay, R-ready delay, and AW/W arrival
order. Crosses: operation x register, and register x response (impossible combinations are excluded).
Run it
Open EDA Playground.
Language: SystemVerilog/Verilog. Library: UVM 1.2. Simulator: Synopsys VCS (or Xcelium, Questa or Riviera-PRO).
Leave SVUnit, Easier UVM and TL-Verilog switched off.
Paste `testbench.sv` into the Testbench pane and `design.sv` into the Design pane, then run.
Search the log for `PASS` and `COV`.
Files
```
design.sv                     DUT, interface, assertions, cover properties
testbench.sv                  UVM environment, sequences, coverage, top module
results/vcs_run_summary.txt   result lines copied from the VCS run
```
Scope and limits
Single outstanding transaction per direction; no pipelined or interleaved accesses.
No UVM register model (RAL): register checking is done by the scoreboard's reference model.
Verified in simulation only; there is no formal proof or gate-level run.
