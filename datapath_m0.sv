// ============================================================================
// Module: datapath_m0
// Description: M0 single-cycle datapath top-level. Wires alu, regfile,
//              imm_gen, control_decoder, and alu_control together for the
//              instruction → decode → regfile read → ALU → writeback path.
//              No PC, no instruction memory, no data memory, no branches,
//              no loads/stores, no forwarding. M0 scope per ar April 2026.
// M0 known limitations (to be resolved in M1):
//   - JAL/JALR: rd receives ALU result, NOT PC+4 (no PC available in M0).
//   - AUIPC: result is imm (PC substituted with 0; wrong but expected).
//   - jalr_target computed here (gotchas.md #6) but not wired to PC mux
//     (no PC mux in M0); will be connected in M1.
//   - halt_nc/illegal_instr_nc must be promoted to top-level ports in M1.
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================

module datapath_m0 (
  input  logic        clk,
  input  logic        rst_n,           // active-low async reset

  input  logic [31:0] instr_i,         // instruction word (from testbench)

  // Testbench observability outputs
  output logic [31:0] alu_result_o,    // ALU result this cycle
  output logic        reg_write_o,     // register file write enable (control)
  output logic [ 4:0] rd_addr_o        // destination register this cycle
);

  // --------------------------------------------------------------------------
  // Instruction field extraction (canonical-reference.md §3)
  // --------------------------------------------------------------------------
  logic [4:0] rs1_addr;
  logic [4:0] rs2_addr;
  logic [4:0] rd_addr;
  logic [2:0] funct3;
  logic       funct7b5;

  assign rs1_addr = instr_i[19:15];
  assign rs2_addr = instr_i[24:20];
  assign rd_addr  = instr_i[11:7];
  assign funct3   = instr_i[14:12];
  assign funct7b5 = instr_i[30];

  // --------------------------------------------------------------------------
  // Internal signal declarations
  // --------------------------------------------------------------------------

  // Used control signals
  logic        reg_write;
  logic        alu_src;
  logic [ 1:0] alu_src_a;
  logic [ 2:0] imm_type;
  logic [ 1:0] alu_op;

  // Unused control_decoder outputs in M0 scope.
  // Connected to named signals (not left truly floating) so that synthesis
  // does not warn on undriven nets while the M0 scope limitation is explicit.
  logic        mem_read_nc;       // loads: unused in M0
  logic        mem_write_nc;      // stores: unused in M0
  logic        mem_to_reg_nc;     // WB mux sel: unused in M0
  logic        branch_nc;         // branch enable: unused in M0
  logic        jump_nc;           // JAL/JALR: unused in M0
  logic        jalr_nc;           // JALR distinguish: unused in M0
  // ⚠ M1 TODO: promote halt_nc and illegal_instr_nc to top-level output
  // ports before tape-out so illegal opcodes / ECALL are externally visible.
  logic        halt_nc;           // ECALL/EBREAK halt: unused in M0
  logic        illegal_instr_nc;  // illegal opcode: unused in M0

  // alu_control illegal_o: unused in M0 (no trap path yet)
  logic        alu_illegal_nc;

  // Immediate generator output
  logic [31:0] imm;

  // ALU control select
  logic [ 3:0] alu_ctrl;

  // Register file read data
  logic [31:0] rs1_data;
  logic [31:0] rs2_data;

  // ALU operand mux results
  logic [31:0] alu_a;
  logic [31:0] alu_b;

  // ALU result (wire from alu instance to output and regfile write data)
  logic [31:0] alu_result;

  // JALR LSB-clear (gotchas.md #6). Ownership is here per spec.
  // In M0 there is no PC mux, so jalr_target is declared and computed
  // but not yet connected to any PC-next path. Wire it in for M1.
  logic [31:0] jalr_target;
  assign jalr_target = {alu_result[31:1], 1'b0};

  // --------------------------------------------------------------------------
  // ALU operand A mux (canonical-reference.md §6 LUI/AUIPC note; §6.1)
  //   2'b00 → rs1_data  (R-type, I-type ALU, loads, stores, JALR)
  //   2'b01 → 32'h0     (PC placeholder — no PC in M0; AUIPC/JAL produce
  //                       wrong results in M0, acceptable per ar scope)
  //   2'b10 → 32'h0     (zero — correct for LUI: 0 + U-imm = U-imm)
  // --------------------------------------------------------------------------
  always_comb begin
    alu_a = 32'h0; // default: prevents latch inference (gotchas.md #1)
    case (alu_src_a)
      2'b00:   alu_a = rs1_data;
      2'b01:   alu_a = 32'h0;   // PC placeholder (no PC in M0)
      2'b10:   alu_a = 32'h0;   // zero (LUI: 0 + U-imm = U-imm)
      default: alu_a = 32'h0;
    endcase
  end

  // --------------------------------------------------------------------------
  // ALU operand B mux (canonical-reference.md §6.1)
  //   1'b0 → rs2_data  (R-type)
  //   1'b1 → imm       (I-type, S-type, U-type, B-type, J-type)
  // --------------------------------------------------------------------------
  always_comb begin
    alu_b = 32'h0; // default: prevents latch inference (gotchas.md #1)
    case (alu_src)
      1'b0:    alu_b = rs2_data;
      1'b1:    alu_b = imm;
      default: alu_b = 32'h0;
    endcase
  end

  // --------------------------------------------------------------------------
  // Observable outputs
  // --------------------------------------------------------------------------
  assign reg_write_o  = reg_write;
  assign alu_result_o = alu_result;
  // rd_addr_o: valid only when reg_write=1. Gate to 5'b0 otherwise so
  // testbenches don't misread instr[11:7] as a destination for S/B-type.
  assign rd_addr_o = reg_write ? rd_addr : 5'b0;

  // --------------------------------------------------------------------------
  // Sub-module instantiations
  // --------------------------------------------------------------------------

  // -- Control decoder -------------------------------------------------------
  // Unused M0 outputs (mem_read_o, mem_write_o, mem_to_reg_o, branch_o,
  // jump_o, jalr_o, halt_o, illegal_instr_o) are captured in _nc wires
  // rather than left unconnected to keep the port binding list complete and
  // avoid lint false-positives for undriven outputs.
  control_decoder ctrl_dec (
    .inst_i          (instr_i),
    .reg_write_o     (reg_write),
    .alu_src_o       (alu_src),
    .alu_src_a_o     (alu_src_a),
    .mem_read_o      (mem_read_nc),
    .mem_write_o     (mem_write_nc),
    .mem_to_reg_o    (mem_to_reg_nc),
    .branch_o        (branch_nc),
    .jump_o          (jump_nc),
    .jalr_o          (jalr_nc),
    .imm_type_o      (imm_type),
    .alu_op_o        (alu_op),
    .halt_o          (halt_nc),
    .illegal_instr_o (illegal_instr_nc)
  );

  // -- Immediate generator ---------------------------------------------------
  imm_gen imm_gen_unit (
    .inst_i     (instr_i),
    .imm_type_i (imm_type),
    .imm_o      (imm)
  );

  // -- ALU control -----------------------------------------------------------
  alu_control alu_ctrl_unit (
    .alu_op_i   (alu_op),
    .funct3_i   (funct3),
    .funct7b5_i (funct7b5),
    .alu_ctrl_o (alu_ctrl),
    .illegal_o  (alu_illegal_nc)
  );

  // -- Register file ---------------------------------------------------------
  // Write port: alu_result written to rd on posedge clk when reg_write=1.
  // x0 write suppression is inside regfile.sv (wr_addr_i != 5'b0 guard).
  // Read-during-write returns OLD value (no forwarding in M0).
  regfile reg_file (
    .clk         (clk),
    .rst_n       (rst_n),
    .wr_en_i     (reg_write),
    .wr_addr_i   (rd_addr),
    .wr_data_i   (alu_result),
    .rd_addr_a_i (rs1_addr),
    .rd_data_a_o (rs1_data),
    .rd_addr_b_i (rs2_addr),
    .rd_data_b_o (rs2_data)
  );

  // -- ALU -------------------------------------------------------------------
  // alu.sv exposes no zero_o port; zero flag is internal to the ALU module.
  alu alu_unit (
    .a_i        (alu_a),
    .b_i        (alu_b),
    .alu_ctrl_i (alu_ctrl),
    .result_o   (alu_result)
  );

endmodule
