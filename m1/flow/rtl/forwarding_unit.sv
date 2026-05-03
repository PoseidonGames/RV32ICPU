// ============================================================================
// Module: forwarding_unit
// Description: WB-to-EX forwarding unit. Detects when a register written in
//              WB is needed as a source in EX and asserts the appropriate
//              forward enable signals. Combinational only — no state.
//
//              forward_rs1_o is additionally gated by alu_src_a == 2'b00 to
//              prevent corruption when ALU-A is PC (AUIPC/JAL) or zero (LUI).
//              forward_rs2_o is NOT gated because rs2 also feeds the store
//              data path, which must forward regardless of alu_src_a.
//
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================

module forwarding_unit (
  // WB stage — source of forwarded data
  input  logic        wb_reg_write_i,  // WB reg-file write enable
  input  logic [4:0]  wb_rd_i,         // WB destination register address

  // EX stage — consumers needing potentially-forwarded values
  input  logic [4:0]  ex_rs1_i,        // EX source register 1 address
  input  logic [4:0]  ex_rs2_i,        // EX source register 2 address
  input  logic [1:0]  alu_src_a_i,     // ALU-A mux select (00=rs1, 01=PC,
                                        //   10=zero)

  // Forward enable outputs
  output logic        forward_rs1_o,   // 1 = use wb_write_data for rs1
  output logic        forward_rs2_o    // 1 = use wb_write_data for rs2
);

  // -------------------------------------------------------------------------
  // Localparams
  // -------------------------------------------------------------------------
  localparam ALU_SRC_A_RS1 = 2'b00;  // ALU-A mux: register rs1 path

  // -------------------------------------------------------------------------
  // Forwarding logic (gotcha #8: x0 suppression; gotcha #12: alu_src_a gate)
  // -------------------------------------------------------------------------
  always_comb begin
    // Defaults prevent latch inference (gotcha #1)
    forward_rs1_o = 1'b0;
    forward_rs2_o = 1'b0;

    // rs1 forwarding: suppress when ALU-A is not driven from rs1
    // (alu_src_a != 00 means ALU-A is PC or zero — forwarding rs1 would
    // silently corrupt AUIPC, JAL, and LUI results; gotcha #12)
    forward_rs1_o = wb_reg_write_i
                    && (wb_rd_i  != 5'd0)           // gotcha #8
                    && (wb_rd_i  == ex_rs1_i)
                    && (alu_src_a_i == ALU_SRC_A_RS1);

    // rs2 forwarding: no alu_src_a gate — rs2 feeds both ALU-B mux and
    // the store data path; stores must forward even when alu_src_a != 00
    forward_rs2_o = wb_reg_write_i
                    && (wb_rd_i != 5'd0)            // gotcha #8
                    && (wb_rd_i == ex_rs2_i);
  end

endmodule
