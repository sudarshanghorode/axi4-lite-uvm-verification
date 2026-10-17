`timescale 1ns/1ps
`include "uvm_macros.svh"

package axi_lite_pkg;
  import uvm_pkg::*;

  //============================================================================
  // Sequence item
  //============================================================================
  class axi_lite_item extends uvm_sequence_item;
    rand bit            is_write;
    rand bit [7:0]      addr;
    rand bit [31:0]     wdata;
    rand bit [3:0]      wstrb;
    rand int unsigned   aw_delay;        // cycles before AWVALID
    rand int unsigned   w_delay;         // cycles before WVALID
    rand int unsigned   b_ready_delay;   // cycles before BREADY
    rand int unsigned   ar_delay;        // cycles before ARVALID
    rand int unsigned   r_ready_delay;   // cycles before RREADY
    bit [31:0]          rdata;           // observed read data
    bit [1:0]           resp;            // observed BRESP / RRESP

    constraint c_align { addr[1:0] == 2'b00; }
    // ~85% of accesses hit the 4 registers, ~15% go out of range (SLVERR)
    constraint c_addr  { addr dist { [8'h00:8'h0C] :/ 85, [8'h10:8'h3C] :/ 15 }; }
    constraint c_strb  { wstrb dist { 4'hF :/ 40, [4'h0:4'hE] :/ 60 }; }
    constraint c_dly   {
      aw_delay      inside {[0:5]};
      w_delay       inside {[0:5]};
      b_ready_delay inside {[0:4]};
      ar_delay      inside {[0:4]};
      r_ready_delay inside {[0:4]};
    }

    `uvm_object_utils(axi_lite_item)

    function new(string name = "axi_lite_item");
      super.new(name);
    endfunction

    function string convert2string();
      if (is_write)
        return $sformatf("WRITE addr=0x%02h data=0x%08h strb=%04b resp=%0d", addr, wdata, wstrb, resp);
      else
        return $sformatf("READ  addr=0x%02h data=0x%08h resp=%0d", addr, rdata, resp);
    endfunction
  endclass

  //============================================================================
  // Sequences
  //============================================================================
  // Directed: read-back of every register, byte lanes, out-of-range accesses
  class axi_lite_directed_seq extends uvm_sequence #(axi_lite_item);
    `uvm_object_utils(axi_lite_directed_seq)

    function new(string name = "axi_lite_directed_seq");
      super.new(name);
    endfunction

    task do_txn(bit wr, bit [7:0] a, bit [31:0] d = 32'h0, bit [3:0] s = 4'hF);
      axi_lite_item t;
      t = axi_lite_item::type_id::create("t");
      start_item(t);
      if (!t.randomize() with { is_write == wr; addr == a; wdata == d; wstrb == s; }) begin
        `uvm_fatal("SEQ", "randomize failed")
      end
      finish_item(t);
    endtask

    task body();
      // 1) write then read back each register with full strobes
      for (int i = 0; i < 4; i++) begin
        do_txn(1, i*4, 32'hA5A5_0000 + i, 4'hF);
        do_txn(0, i*4);
      end
      // 2) byte-lane writes into register 0
      do_txn(1, 8'h00, 32'hFFFF_FFFF, 4'hF);
      for (int b = 0; b < 4; b++) begin
        do_txn(1, 8'h00, 32'h0000_0000, 4'h1 << b);
        do_txn(0, 8'h00);
      end
      // 3) write with no byte enabled must not change the register
      do_txn(1, 8'h04, 32'h1234_5678, 4'h0);
      do_txn(0, 8'h04);
      // 4) out-of-range accesses -> SLVERR
      do_txn(1, 8'h10, 32'hDEAD_BEEF, 4'hF);
      do_txn(0, 8'h10);
      do_txn(1, 8'h3C, 32'h1234_5678, 4'hF);
      do_txn(0, 8'h20);
    endtask
  endclass

  // Constrained-random traffic
  class axi_lite_rand_seq extends uvm_sequence #(axi_lite_item);
    `uvm_object_utils(axi_lite_rand_seq)
    int unsigned num_txn = 1000;

    function new(string name = "axi_lite_rand_seq");
      super.new(name);
    endfunction

    task body();
      axi_lite_item t;
      repeat (num_txn) begin
        t = axi_lite_item::type_id::create("t");
        start_item(t);
        if (!t.randomize()) begin
          `uvm_fatal("SEQ", "randomize failed")
        end
        finish_item(t);
      end
    endtask
  endclass

  //============================================================================
  // Driver
  //============================================================================
  class axi_lite_driver extends uvm_driver #(axi_lite_item);
    `uvm_component_utils(axi_lite_driver)

    virtual axi_lite_if                vif;
    uvm_analysis_port #(axi_lite_item) ap;     // completed stimulus -> coverage

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      ap = new("ap", this);
      if (!uvm_config_db #(virtual axi_lite_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("DRV", "virtual interface 'vif' not set")
      end
    endfunction

    task run_phase(uvm_phase phase);
      wait (vif.ARESETn === 1'b1);
      repeat (2) @(vif.drv_cb);
      forever begin
        seq_item_port.get_next_item(req);
        if (req.is_write) drive_write(req);
        else              drive_read(req);
        ap.write(req);
        seq_item_port.item_done();
      end
    endtask

    task drive_write(axi_lite_item t);
      fork
        begin : aw_thread
          repeat (t.aw_delay) @(vif.drv_cb);
          vif.drv_cb.AWADDR  <= t.addr;
          vif.drv_cb.AWVALID <= 1'b1;
          do begin @(vif.drv_cb); end while (!vif.drv_cb.AWREADY);
          vif.drv_cb.AWVALID <= 1'b0;
        end
        begin : w_thread
          repeat (t.w_delay) @(vif.drv_cb);
          vif.drv_cb.WDATA  <= t.wdata;
          vif.drv_cb.WSTRB  <= t.wstrb;
          vif.drv_cb.WVALID <= 1'b1;
          do begin @(vif.drv_cb); end while (!vif.drv_cb.WREADY);
          vif.drv_cb.WVALID <= 1'b0;
        end
      join
      repeat (t.b_ready_delay) @(vif.drv_cb);
      vif.drv_cb.BREADY <= 1'b1;
      do begin @(vif.drv_cb); end while (!vif.drv_cb.BVALID);
      t.resp = vif.drv_cb.BRESP;
      vif.drv_cb.BREADY <= 1'b0;
    endtask

    task drive_read(axi_lite_item t);
      repeat (t.ar_delay) @(vif.drv_cb);
      vif.drv_cb.ARADDR  <= t.addr;
      vif.drv_cb.ARVALID <= 1'b1;
      do begin @(vif.drv_cb); end while (!vif.drv_cb.ARREADY);
      vif.drv_cb.ARVALID <= 1'b0;
      repeat (t.r_ready_delay) @(vif.drv_cb);
      vif.drv_cb.RREADY <= 1'b1;
      do begin @(vif.drv_cb); end while (!vif.drv_cb.RVALID);
      t.rdata = vif.drv_cb.RDATA;
      t.resp  = vif.drv_cb.RRESP;
      vif.drv_cb.RREADY <= 1'b0;
    endtask
  endclass

  //============================================================================
  // Monitor: rebuilds transactions purely from observed handshakes
  //============================================================================
  class axi_lite_monitor extends uvm_monitor;
    `uvm_component_utils(axi_lite_monitor)

    virtual axi_lite_if                vif;
    uvm_analysis_port #(axi_lite_item) ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      ap = new("ap", this);
      if (!uvm_config_db #(virtual axi_lite_if)::get(this, "", "vif", vif)) begin
        `uvm_fatal("MON", "virtual interface 'vif' not set")
      end
    endfunction

    task run_phase(uvm_phase phase);
      axi_lite_item it;
      bit [7:0]  aw_q [$];
      bit [31:0] wd_q [$];
      bit [3:0]  ws_q [$];
      bit [7:0]  ar_q [$];

      forever begin
        @(vif.mon_cb);

        if (vif.mon_cb.AWVALID && vif.mon_cb.AWREADY)
          aw_q.push_back(vif.mon_cb.AWADDR);

        if (vif.mon_cb.WVALID && vif.mon_cb.WREADY) begin
          wd_q.push_back(vif.mon_cb.WDATA);
          ws_q.push_back(vif.mon_cb.WSTRB);
        end

        if (vif.mon_cb.BVALID && vif.mon_cb.BREADY) begin
          if (aw_q.size() > 0 && wd_q.size() > 0) begin
            it = axi_lite_item::type_id::create("mon_wr");
            it.is_write = 1'b1;
            it.addr     = aw_q.pop_front();
            it.wdata    = wd_q.pop_front();
            it.wstrb    = ws_q.pop_front();
            it.resp     = vif.mon_cb.BRESP;
            `uvm_info("MON", it.convert2string(), UVM_HIGH)
            ap.write(it);
          end else begin
            `uvm_error("MON", "write response seen without a matching address/data handshake")
          end
        end

        if (vif.mon_cb.ARVALID && vif.mon_cb.ARREADY)
          ar_q.push_back(vif.mon_cb.ARADDR);

        if (vif.mon_cb.RVALID && vif.mon_cb.RREADY) begin
          if (ar_q.size() > 0) begin
            it = axi_lite_item::type_id::create("mon_rd");
            it.is_write = 1'b0;
            it.addr     = ar_q.pop_front();
            it.rdata    = vif.mon_cb.RDATA;
            it.resp     = vif.mon_cb.RRESP;
            `uvm_info("MON", it.convert2string(), UVM_HIGH)
            ap.write(it);
          end else begin
            `uvm_error("MON", "read data seen without a matching address handshake")
          end
        end
      end
    endtask
  endclass

  //============================================================================
  // Agent
  //============================================================================
  class axi_lite_agent extends uvm_agent;
    `uvm_component_utils(axi_lite_agent)

    axi_lite_driver                drv;
    uvm_sequencer #(axi_lite_item) sqr;
    axi_lite_monitor               mon;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      drv = axi_lite_driver::type_id::create("drv", this);
      sqr = uvm_sequencer #(axi_lite_item)::type_id::create("sqr", this);
      mon = axi_lite_monitor::type_id::create("mon", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  //============================================================================
  // Scoreboard: reference model of the 4 registers
  //============================================================================
  class axi_lite_scoreboard extends uvm_subscriber #(axi_lite_item);
    `uvm_component_utils(axi_lite_scoreboard)

    bit [31:0]   ref_regs [4];
    int unsigned n_wr, n_rd, n_err;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      foreach (ref_regs[i]) ref_regs[i] = 32'h0;
    endfunction

    function void write(axi_lite_item t);
      bit        in_range;
      bit [1:0]  exp_resp;
      bit [31:0] exp_data;

      in_range = (t.addr[7:2] < 4);
      exp_resp = in_range ? 2'b00 : 2'b10;

      if (t.is_write) begin
        n_wr++;
        if (t.resp !== exp_resp) begin
          n_err++;
          `uvm_error("SCB", $sformatf("BRESP mismatch: exp=%0d got=%0d (%s)", exp_resp, t.resp, t.convert2string()))
        end
        if (in_range) begin
          for (int b = 0; b < 4; b++)
            if (t.wstrb[b]) ref_regs[t.addr[3:2]][8*b +: 8] = t.wdata[8*b +: 8];
        end
      end else begin
        n_rd++;
        exp_data = in_range ? ref_regs[t.addr[3:2]] : 32'h0;
        if (t.resp !== exp_resp) begin
          n_err++;
          `uvm_error("SCB", $sformatf("RRESP mismatch: exp=%0d got=%0d (%s)", exp_resp, t.resp, t.convert2string()))
        end
        if (t.rdata !== exp_data) begin
          n_err++;
          `uvm_error("SCB", $sformatf("RDATA mismatch: exp=0x%08h got=0x%08h (%s)", exp_data, t.rdata, t.convert2string()))
        end
      end
    endfunction

    function void report_phase(uvm_phase phase);
      if (n_err == 0 && (n_wr + n_rd) > 0) begin
        `uvm_info("SCB", $sformatf("PASS: %0d writes and %0d reads checked, 0 mismatches", n_wr, n_rd), UVM_NONE)
      end else begin
        `uvm_error("SCB", $sformatf("FAIL: %0d mismatches in %0d writes / %0d reads", n_err, n_wr, n_rd))
      end
    endfunction
  endclass

  //============================================================================
  // Functional coverage (fed by the driver's completed transactions)
  //============================================================================
  class axi_lite_coverage extends uvm_subscriber #(axi_lite_item);
    `uvm_component_utils(axi_lite_coverage)

    covergroup cg with function sample(axi_lite_item t);
      option.per_instance = 1;
      option.name         = "axi_lite_cov";

      cp_op : coverpoint t.is_write {
        bins read  = {1'b0};
        bins write = {1'b1};
      }

      cp_reg : coverpoint t.addr[7:2] {
        bins reg0         = {6'd0};
        bins reg1         = {6'd1};
        bins reg2         = {6'd2};
        bins reg3         = {6'd3};
        bins out_of_range = {[6'd4:6'd63]};
      }

      cp_resp : coverpoint t.resp {
        bins okay   = {2'b00};
        bins slverr = {2'b10};
      }

      // byte-strobe patterns on writes: none / one / two / three / all lanes
      cp_strb : coverpoint t.wstrb iff (t.is_write) {
        bins none            = {4'h0};
        bins single_lane[]   = {4'h1, 4'h2, 4'h4, 4'h8};
        bins two_lanes[]     = {4'h3, 4'h5, 4'h6, 4'h9, 4'hA, 4'hC};
        bins three_lanes[]   = {4'h7, 4'hB, 4'hD, 4'hE};
        bins all_lanes       = {4'hF};
      }

      // handshake timing: delays before VALID / READY
      cp_aw_delay : coverpoint t.aw_delay iff (t.is_write) {
        bins zero = {0}; bins short_d = {[1:2]}; bins long_d = {[3:$]};
      }
      cp_w_delay : coverpoint t.w_delay iff (t.is_write) {
        bins zero = {0}; bins short_d = {[1:2]}; bins long_d = {[3:$]};
      }
      cp_b_delay : coverpoint t.b_ready_delay iff (t.is_write) {
        bins zero = {0}; bins short_d = {[1:2]}; bins long_d = {[3:$]};
      }
      cp_ar_delay : coverpoint t.ar_delay iff (!t.is_write) {
        bins zero = {0}; bins short_d = {[1:2]}; bins long_d = {[3:$]};
      }
      cp_r_delay : coverpoint t.r_ready_delay iff (!t.is_write) {
        bins zero = {0}; bins short_d = {[1:2]}; bins long_d = {[3:$]};
      }

      // which write channel arrives first
      cp_order : coverpoint (t.aw_delay < t.w_delay ? 0 : (t.aw_delay == t.w_delay ? 1 : 2)) iff (t.is_write) {
        bins aw_first = {0};
        bins together = {1};
        bins w_first  = {2};
      }

      cx_op_reg  : cross cp_op, cp_reg;
      cx_reg_resp : cross cp_reg, cp_resp {
        ignore_bins oob_cannot_be_okay = binsof(cp_reg.out_of_range) && binsof(cp_resp.okay);
        ignore_bins reg_cannot_error   = (binsof(cp_reg.reg0) || binsof(cp_reg.reg1) ||
                                          binsof(cp_reg.reg2) || binsof(cp_reg.reg3)) &&
                                         binsof(cp_resp.slverr);
      }
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg = new();
    endfunction

    function void write(axi_lite_item t);
      cg.sample(t);
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("COV", $sformatf("FUNCTIONAL COVERAGE (axi_lite_cov) = %0.2f %%", cg.get_inst_coverage()), UVM_NONE)
      `uvm_info("COV", $sformatf("  read/write operation    = %0.2f %%", cg.cp_op.get_inst_coverage()), UVM_NONE)
      `uvm_info("COV", $sformatf("  register address        = %0.2f %%", cg.cp_reg.get_inst_coverage()), UVM_NONE)
      `uvm_info("COV", $sformatf("  response (OKAY/SLVERR)  = %0.2f %%", cg.cp_resp.get_inst_coverage()), UVM_NONE)
      `uvm_info("COV", $sformatf("  byte-strobe patterns    = %0.2f %%", cg.cp_strb.get_inst_coverage()), UVM_NONE)
      `uvm_info("COV", $sformatf("  AW delay                = %0.2f %%", cg.cp_aw_delay.get_inst_coverage()), UVM_NONE)
      `uvm_info("COV", $sformatf("  W delay                 = %0.2f %%", cg.cp_w_delay.get_inst_coverage()), UVM_NONE)
      `uvm_info("COV", $sformatf("  B-ready delay           = %0.2f %%", cg.cp_b_delay.get_inst_coverage()), UVM_NONE)
      `uvm_info("COV", $sformatf("  AR delay                = %0.2f %%", cg.cp_ar_delay.get_inst_coverage()), UVM_NONE)
      `uvm_info("COV", $sformatf("  R-ready delay           = %0.2f %%", cg.cp_r_delay.get_inst_coverage()), UVM_NONE)
      `uvm_info("COV", $sformatf("  AW/W arrival order      = %0.2f %%", cg.cp_order.get_inst_coverage()), UVM_NONE)
      `uvm_info("COV", $sformatf("  cross: operation x reg  = %0.2f %%", cg.cx_op_reg.get_inst_coverage()), UVM_NONE)
      `uvm_info("COV", $sformatf("  cross: register x resp  = %0.2f %%", cg.cx_reg_resp.get_inst_coverage()), UVM_NONE)
    endfunction
  endclass

  //============================================================================
  // Environment
  //============================================================================
  class axi_lite_env extends uvm_env;
    `uvm_component_utils(axi_lite_env)

    axi_lite_agent      agent;
    axi_lite_scoreboard scb;
    axi_lite_coverage   cov;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agent = axi_lite_agent::type_id::create("agent", this);
      scb   = axi_lite_scoreboard::type_id::create("scb", this);
      cov   = axi_lite_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agent.mon.ap.connect(scb.analysis_export);   // observed -> scoreboard
      agent.drv.ap.connect(cov.analysis_export);   // stimulus -> coverage
    endfunction
  endclass

  //============================================================================
  // Test
  //============================================================================
  class axi_lite_test extends uvm_test;
    `uvm_component_utils(axi_lite_test)

    axi_lite_env env;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = axi_lite_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      axi_lite_directed_seq dseq;
      axi_lite_rand_seq     rseq;
      int unsigned          n;

      phase.raise_objection(this);
      phase.phase_done.set_drain_time(this, 100ns);

      dseq = axi_lite_directed_seq::type_id::create("dseq");
      dseq.start(env.agent.sqr);

      rseq = axi_lite_rand_seq::type_id::create("rseq");
      if ($value$plusargs("NUM_TXN=%d", n)) rseq.num_txn = n;   // e.g. +NUM_TXN=5000
      rseq.start(env.agent.sqr);

      phase.drop_objection(this);
    endtask
  endclass

endpackage

//==============================================================================
// Top module
//==============================================================================
module tb_top;
  import uvm_pkg::*;
  import axi_lite_pkg::*;

  logic ACLK    = 1'b0;
  logic ARESETn = 1'b0;

  always #5 ACLK = ~ACLK;                       // 100 MHz

  initial begin                                 // release reset after 5 clocks
    repeat (5) @(posedge ACLK);
    #1 ARESETn = 1'b1;
  end

  axi_lite_if vif (.ACLK(ACLK), .ARESETn(ARESETn));

  axi_lite_slave #(.ADDR_W(8), .DATA_W(32), .NUM_REGS(4)) dut (
    .ACLK(ACLK), .ARESETn(ARESETn),
    .AWADDR(vif.AWADDR), .AWVALID(vif.AWVALID), .AWREADY(vif.AWREADY),
    .WDATA(vif.WDATA),   .WSTRB(vif.WSTRB),     .WVALID(vif.WVALID), .WREADY(vif.WREADY),
    .BRESP(vif.BRESP),   .BVALID(vif.BVALID),   .BREADY(vif.BREADY),
    .ARADDR(vif.ARADDR), .ARVALID(vif.ARVALID), .ARREADY(vif.ARREADY),
    .RDATA(vif.RDATA),   .RRESP(vif.RRESP),     .RVALID(vif.RVALID), .RREADY(vif.RREADY)
  );

  initial begin
    uvm_config_db #(virtual axi_lite_if)::set(null, "*", "vif", vif);
    run_test("axi_lite_test");
  end

  initial begin                                 // waveform for EPWave
    $dumpfile("dump.vcd");
    $dumpvars(0);
  end

  initial begin                                 // watchdog
    #200ms;
    $fatal(1, "TB timeout");
  end
endmodule
