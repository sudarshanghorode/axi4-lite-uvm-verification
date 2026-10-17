`timescale 1ns/1ps

//------------------------------------------------------------------------------
// DUT: AXI4-Lite slave with 4 x 32-bit registers (word addresses 0x00..0x0C)
//   - byte-lane writes through WSTRB
//   - OKAY  (2'b00) response for addresses inside the register file
//   - SLVERR(2'b10) response for addresses outside the register file
//   - one outstanding write and one outstanding read at a time
//------------------------------------------------------------------------------
module axi_lite_slave #(
  parameter int ADDR_W   = 8,
  parameter int DATA_W   = 32,
  parameter int NUM_REGS = 4
)(
  input  logic                 ACLK,
  input  logic                 ARESETn,
  // write address channel
  input  logic [ADDR_W-1:0]    AWADDR,
  input  logic                 AWVALID,
  output logic                 AWREADY,
  // write data channel
  input  logic [DATA_W-1:0]    WDATA,
  input  logic [DATA_W/8-1:0]  WSTRB,
  input  logic                 WVALID,
  output logic                 WREADY,
  // write response channel
  output logic [1:0]           BRESP,
  output logic                 BVALID,
  input  logic                 BREADY,
  // read address channel
  input  logic [ADDR_W-1:0]    ARADDR,
  input  logic                 ARVALID,
  output logic                 ARREADY,
  // read data channel
  output logic [DATA_W-1:0]    RDATA,
  output logic [1:0]           RRESP,
  output logic                 RVALID,
  input  logic                 RREADY
);

  localparam int STRB_W = DATA_W/8;
  localparam int IDX_W  = $clog2(NUM_REGS);

  logic [DATA_W-1:0] regs [NUM_REGS];

  //---------------------------- write path ------------------------------------
  logic                aw_got, w_got;
  logic [ADDR_W-1:0]   aw_addr_q;
  logic [DATA_W-1:0]   w_data_q;
  logic [STRB_W-1:0]   w_strb_q;
  logic [IDX_W-1:0]    widx;

  assign widx    = aw_addr_q[2 +: IDX_W];
  assign AWREADY = ~aw_got & ~BVALID;
  assign WREADY  = ~w_got  & ~BVALID;

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      aw_got    <= 1'b0;
      w_got     <= 1'b0;
      aw_addr_q <= '0;
      w_data_q  <= '0;
      w_strb_q  <= '0;
      BVALID    <= 1'b0;
      BRESP     <= 2'b00;
      for (int i = 0; i < NUM_REGS; i++) regs[i] <= '0;
    end else begin
      if (AWVALID && AWREADY) begin
        aw_got    <= 1'b1;
        aw_addr_q <= AWADDR;
      end
      if (WVALID && WREADY) begin
        w_got    <= 1'b1;
        w_data_q <= WDATA;
        w_strb_q <= WSTRB;
      end

      // both address and data have arrived -> perform the write
      if (aw_got && w_got && !BVALID) begin
        if (aw_addr_q[ADDR_W-1:2] < NUM_REGS) begin
          for (int b = 0; b < STRB_W; b++)
            if (w_strb_q[b]) regs[widx][8*b +: 8] <= w_data_q[8*b +: 8];
          BRESP <= 2'b00;   // OKAY
        end else begin
          BRESP <= 2'b10;   // SLVERR
        end
        BVALID <= 1'b1;
        aw_got <= 1'b0;
        w_got  <= 1'b0;
      end

      if (BVALID && BREADY) BVALID <= 1'b0;
    end
  end

  //---------------------------- read path -------------------------------------
  assign ARREADY = ~RVALID;

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      RVALID <= 1'b0;
      RDATA  <= '0;
      RRESP  <= 2'b00;
    end else begin
      if (ARVALID && ARREADY) begin
        RVALID <= 1'b1;
        if (ARADDR[ADDR_W-1:2] < NUM_REGS) begin
          RDATA <= regs[ARADDR[2 +: IDX_W]];
          RRESP <= 2'b00;   // OKAY
        end else begin
          RDATA <= '0;
          RRESP <= 2'b10;   // SLVERR
        end
      end else if (RVALID && RREADY) begin
        RVALID <= 1'b0;
      end
    end
  end

endmodule

//------------------------------------------------------------------------------
// AXI4-Lite interface: signals, clocking blocks for UVM, protocol assertions
//------------------------------------------------------------------------------
interface axi_lite_if #(parameter int ADDR_W = 8, parameter int DATA_W = 32)
                       (input logic ACLK, input logic ARESETn);

  // write address channel
  logic [ADDR_W-1:0]   AWADDR  = '0;
  logic                AWVALID = 1'b0;
  logic                AWREADY;
  // write data channel
  logic [DATA_W-1:0]   WDATA   = '0;
  logic [DATA_W/8-1:0] WSTRB   = '0;
  logic                WVALID  = 1'b0;
  logic                WREADY;
  // write response channel
  logic [1:0]          BRESP;
  logic                BVALID;
  logic                BREADY  = 1'b0;
  // read address channel
  logic [ADDR_W-1:0]   ARADDR  = '0;
  logic                ARVALID = 1'b0;
  logic                ARREADY;
  // read data channel
  logic [DATA_W-1:0]   RDATA;
  logic [1:0]          RRESP;
  logic                RVALID;
  logic                RREADY  = 1'b0;

  // driver view (master side)
  clocking drv_cb @(posedge ACLK);
    default input #1step output #1ns;
    output AWADDR, AWVALID, WDATA, WSTRB, WVALID, BREADY, ARADDR, ARVALID, RREADY;
    input  AWREADY, WREADY, BRESP, BVALID, ARREADY, RDATA, RRESP, RVALID;
  endclocking

  // monitor view (everything is an input)
  clocking mon_cb @(posedge ACLK);
    default input #1step;
    input AWADDR, AWVALID, AWREADY, WDATA, WSTRB, WVALID, WREADY,
          BRESP, BVALID, BREADY, ARADDR, ARVALID, ARREADY,
          RDATA, RRESP, RVALID, RREADY;
  endclocking

  //---------------------------- SystemVerilog Assertions ----------------------
  // VALID must stay high, with stable payload, until the matching READY
  a_aw_stable : assert property (@(posedge ACLK) disable iff (!ARESETn)
      (AWVALID && !AWREADY) |=> (AWVALID && $stable(AWADDR)))
      else $error("AXI-Lite: AW channel changed before AWREADY");

  a_w_stable  : assert property (@(posedge ACLK) disable iff (!ARESETn)
      (WVALID && !WREADY) |=> (WVALID && $stable(WDATA) && $stable(WSTRB)))
      else $error("AXI-Lite: W channel changed before WREADY");

  a_ar_stable : assert property (@(posedge ACLK) disable iff (!ARESETn)
      (ARVALID && !ARREADY) |=> (ARVALID && $stable(ARADDR)))
      else $error("AXI-Lite: AR channel changed before ARREADY");

  a_b_hold    : assert property (@(posedge ACLK) disable iff (!ARESETn)
      (BVALID && !BREADY) |=> (BVALID && $stable(BRESP)))
      else $error("AXI-Lite: B channel changed before BREADY");

  a_r_hold    : assert property (@(posedge ACLK) disable iff (!ARESETn)
      (RVALID && !RREADY) |=> (RVALID && $stable(RDATA) && $stable(RRESP)))
      else $error("AXI-Lite: R channel changed before RREADY");

  // AXI4-Lite does not support EXOKAY
  a_bresp_legal : assert property (@(posedge ACLK) disable iff (!ARESETn)
      BVALID |-> (BRESP != 2'b01))
      else $error("AXI-Lite: illegal BRESP (EXOKAY)");

  a_rresp_legal : assert property (@(posedge ACLK) disable iff (!ARESETn)
      RVALID |-> (RRESP != 2'b01))
      else $error("AXI-Lite: illegal RRESP (EXOKAY)");

  // cover the interesting protocol corners
  c_slverr_write : cover property (@(posedge ACLK) disable iff (!ARESETn) BVALID && BREADY && BRESP == 2'b10);
  c_slverr_read  : cover property (@(posedge ACLK) disable iff (!ARESETn) RVALID && RREADY && RRESP == 2'b10);
  c_b_backpress  : cover property (@(posedge ACLK) disable iff (!ARESETn) BVALID && !BREADY);
  c_r_backpress  : cover property (@(posedge ACLK) disable iff (!ARESETn) RVALID && !RREADY);

endinterface
