// ============================================================================
// Module: pipeline_top
// Description: RV32I 3-stage pipeline integration top-level (M1 milestone).
//              Stages: IF (fetch) -> EX (decode+execute+mem) -> WB (writeback).
//              Contains: PC register, PC+4 adder, IF/EX and EX/WB pipeline
//              registers, forwarding muxes, ALU-A/B muxes, WB mux, PC-next
//              mux, branch target adder, flush logic, and halt output.
//              Instantiates all 8 leaf modules: alu, regfile, imm_gen,
//              control_decoder, alu_control, branch_comparator,
//              load_store_unit, forwarding_unit.
// Author: Beaux Cable
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
// ============================================================================

module pipeline_top (
  input  logic        clk,
  input  logic        rst_n,            // active-low async reset

  // Instruction memory interface (IF stage)
  output logic [31:0] instr_addr_o,     // PC -> instruction memory
  input  logic [31:0] instr_data_i,     // instruction word from memory

  // Data memory interface (EX stage)
  output logic [31:0] data_addr_o,      // effective address (ALU result)
  output logic [31:0] data_out_o,       // store data (byte-lane aligned)
  output logic [3:0]  data_we_o,        // byte write enables, active-high
  output logic        data_re_o,        // read enable (gated by valid)
  input  logic [31:0] data_in_i,        // load data from memory

  // Processor status
  output logic        halt_o            // ECALL/EBREAK or illegal instruction
);

  // ==========================================================================
  // Localparams
  // ==========================================================================

  // NOP = ADDI x0, x0, 0 (canonical-reference.md §7.3; gotcha #9)
  localparam logic [31:0] NOP_INSTR = 32'h00000013;

  // ALU-A source select encoding (canonical-reference.md §6.1)
  localparam logic [1:0] ALU_SRCA_RS1  = 2'b00;
  localparam logic [1:0] ALU_SRCA_PC   = 2'b01;
  localparam logic [1:0] ALU_SRCA_ZERO = 2'b10;

  // ==========================================================================
  // IF stage — PC register and PC+4 adder
  // ==========================================================================

  logic [31:0] pc_reg;       // current program counter
  logic [31:0] pc_plus_4;    // pc_reg + 4
  logic [31:0] pc_next;      // next-cycle PC value (resolved in EX)

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      pc_reg <= 32'h0;
    else
      pc_reg <= pc_next;
  end

  assign pc_plus_4    = pc_reg + 32'd4;
  assign instr_addr_o = pc_reg;

  // ==========================================================================
  // IF/EX pipeline register
  // Flush inserts NOP bubble on taken branch or any jump (gotcha #9).
  // ==========================================================================

  logic [31:0] if_ex_instr;     // latched instruction word
  logic [31:0] if_ex_pc;        // latched PC of this instruction
  logic [31:0] if_ex_pc_plus_4; // latched PC+4
  logic        if_ex_valid;     // 0 = bubble/NOP

  logic flush_if_ex;            // flush strobe (computed in EX)

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      if_ex_instr     <= NOP_INSTR;
      if_ex_pc        <= 32'h0;
      if_ex_pc_plus_4 <= 32'd4;
      if_ex_valid     <= 1'b0;
    end else if (flush_if_ex) begin
      // Insert NOP bubble; PC fields are don't-care but zeroed for tidiness
      if_ex_instr     <= NOP_INSTR;
      if_ex_pc        <= 32'h0;
      if_ex_pc_plus_4 <= 32'd4;
      if_ex_valid     <= 1'b0;
    end else begin
      if_ex_instr     <= instr_data_i;
      if_ex_pc        <= pc_reg;
      if_ex_pc_plus_4 <= pc_plus_4;
      if_ex_valid     <= 1'b1;
    end
  end

  // ==========================================================================
  // EX stage — instruction field extraction
  // ==========================================================================

  // Fields extracted from the latched instruction word
  logic [6:0] ex_opcode;
  logic [4:0] ex_rd_addr;
  logic [4:0] ex_rs1_addr;
  logic [4:0] ex_rs2_addr;
  logic [2:0] ex_funct3;
  logic       ex_funct7b5;

  assign ex_opcode   = if_ex_instr[6:0];
  assign ex_rd_addr  = if_ex_instr[11:7];
  assign ex_rs1_addr = if_ex_instr[19:15];
  assign ex_rs2_addr = if_ex_instr[24:20];
  assign ex_funct3   = if_ex_instr[14:12];
  assign ex_funct7b5 = if_ex_instr[30];    // funct7[5]

  // ==========================================================================
  // EX stage — control decoder outputs
  // ==========================================================================

  logic        ex_reg_write;
  logic        ex_alu_src;
  logic [1:0]  ex_alu_src_a;
  logic        ex_mem_read;
  logic        ex_mem_write;
  logic        ex_mem_to_reg;
  logic        ex_branch;
  logic        ex_jump;
  logic        ex_jalr;
  logic [2:0]  ex_imm_type;
  logic [1:0]  ex_alu_op;
  logic        ex_halt;
  logic        ex_illegal_instr;

  control_decoder ctrl_dec (
    .inst_i         (if_ex_instr),
    .reg_write_o    (ex_reg_write),
    .alu_src_o      (ex_alu_src),
    .alu_src_a_o    (ex_alu_src_a),
    .mem_read_o     (ex_mem_read),
    .mem_write_o    (ex_mem_write),
    .mem_to_reg_o   (ex_mem_to_reg),
    .branch_o       (ex_branch),
    .jump_o         (ex_jump),
    .jalr_o         (ex_jalr),
    .imm_type_o     (ex_imm_type),
    .alu_op_o       (ex_alu_op),
    .halt_o         (ex_halt),
    .illegal_instr_o(ex_illegal_instr)
  );

  // ==========================================================================
  // EX stage — immediate generator
  // ==========================================================================

  logic [31:0] ex_imm;

  imm_gen imm_generator (
    .inst_i    (if_ex_instr),
    .imm_type_i(ex_imm_type),
    .imm_o     (ex_imm)
  );

  // ==========================================================================
  // EX stage — register file
  // Read addresses come from EX instruction; write port driven from WB stage.
  // ==========================================================================

  logic [31:0] rs1_data;    // raw read-port A output
  logic [31:0] rs2_data;    // raw read-port B output

  // WB-stage signals (driven by EX/WB pipeline register below)
  logic [31:0] wb_write_data;
  logic [4:0]  wb_rd;
  logic        wb_reg_write;

  regfile reg_file (
    .clk        (clk),
    .rst_n      (rst_n),
    // Write port — driven from WB stage
    .wr_en_i    (wb_reg_write),
    .wr_addr_i  (wb_rd),
    .wr_data_i  (wb_write_data),
    // Read port A — rs1
    .rd_addr_a_i(ex_rs1_addr),
    .rd_data_a_o(rs1_data),
    // Read port B — rs2
    .rd_addr_b_i(ex_rs2_addr),
    .rd_data_b_o(rs2_data)
  );

  // ==========================================================================
  // EX stage — forwarding unit
  // ==========================================================================

  logic forward_rs1;
  logic forward_rs2;

  forwarding_unit fwd_unit (
    .wb_reg_write_i(wb_reg_write),
    .wb_rd_i       (wb_rd),
    .ex_rs1_i      (ex_rs1_addr),
    .ex_rs2_i      (ex_rs2_addr),
    .alu_src_a_i   (ex_alu_src_a),
    .forward_rs1_o (forward_rs1),
    .forward_rs2_o (forward_rs2)
  );

  // ==========================================================================
  // EX stage — forwarding muxes
  // ==========================================================================

  logic [31:0] rs1_fwd;  // rs1 after WB-to-EX forwarding
  logic [31:0] rs2_fwd;  // rs2 after WB-to-EX forwarding

  assign rs1_fwd = forward_rs1 ? wb_write_data : rs1_data;
  assign rs2_fwd = forward_rs2 ? wb_write_data : rs2_data;

  // ==========================================================================
  // EX stage — ALU-A and ALU-B muxes
  // ALU-A: 00=rs1_fwd (default), 01=if_ex_pc (AUIPC/JAL), 10=zero (LUI)
  // ALU-B: alu_src ? ex_imm : rs2_fwd
  // ==========================================================================

  logic [31:0] alu_a;
  logic [31:0] alu_b;

  always_comb begin
    // Default prevents latch inference (gotcha #1)
    alu_a = 32'h0;
    case (ex_alu_src_a)
      ALU_SRCA_RS1:  alu_a = rs1_fwd;    // rs1 with WB forwarding
      ALU_SRCA_PC:   alu_a = if_ex_pc;   // AUIPC/JAL: current PC (gotcha #7)
      ALU_SRCA_ZERO: alu_a = 32'h0;      // LUI: zero
      default:       alu_a = 32'h0;
    endcase
  end

  assign alu_b = ex_alu_src ? ex_imm : rs2_fwd;

  // ==========================================================================
  // EX stage — ALU control
  // ==========================================================================

  logic [3:0] alu_ctrl;
  logic       alu_ctrl_illegal;

  alu_control alu_ctrl_unit (
    .alu_op_i   (ex_alu_op),
    .funct3_i   (ex_funct3),
    .funct7b5_i (ex_funct7b5),
    .alu_ctrl_o (alu_ctrl),
    .illegal_o  (alu_ctrl_illegal)
  );

  // ==========================================================================
  // EX stage — ALU
  // ==========================================================================

  logic [31:0] alu_result;

  alu alu_unit (
    .a_i       (alu_a),
    .b_i       (alu_b),
    .alu_ctrl_i(alu_ctrl),
    .result_o  (alu_result)
  );

  // ==========================================================================
  // EX stage — JALR LSB clear (gotcha #6)
  // target = (rs1 + sext(imm)) & ~1; always formed from alu_result
  // ==========================================================================

  logic [31:0] jalr_target;
  assign jalr_target = {alu_result[31:1], 1'b0};

  // ==========================================================================
  // EX stage — branch target adder (separate from ALU; gotcha #7)
  // branch_target = if_ex_pc + B-imm (ex_imm when branch=1)
  // ==========================================================================

  logic [31:0] branch_target;
  assign branch_target = if_ex_pc + ex_imm;

  // ==========================================================================
  // EX stage — branch comparator
  // ==========================================================================

  logic branch_taken;

  branch_comparator br_comp (
    .rs1_data_i    (rs1_fwd),
    .rs2_data_i    (rs2_fwd),
    .funct3_i      (ex_funct3),
    .branch_taken_o(branch_taken)
  );

  // ==========================================================================
  // EX stage — load/store unit
  // Store data is rs2_fwd (forwarded); store data path bypasses ALU-B mux.
  // data_we/data_re gated by if_ex_valid to suppress memory access on bubbles.
  // ==========================================================================

  logic [31:0] store_data;
  logic [3:0]  lsu_data_we;
  logic [31:0] load_data;

  // Valid-gated memory control signals (single definition, used by LSU + I/O)
  logic ex_mem_write_gated;
  logic ex_mem_read_gated;
  assign ex_mem_write_gated = ex_mem_write && if_ex_valid;
  assign ex_mem_read_gated  = ex_mem_read  && if_ex_valid;

  load_store_unit lsu (
    .rs2_i       (rs2_fwd),
    .addr_i      (alu_result),
    .funct3_i    (ex_funct3),
    .mem_write_i (ex_mem_write_gated),
    .mem_read_i  (ex_mem_read_gated),
    .store_data_o(store_data),
    .data_we_o   (lsu_data_we),
    .load_raw_i  (data_in_i),
    .load_data_o (load_data)
  );

  // Memory interface outputs; data_we and data_re already gated inside LSU
  assign data_addr_o = alu_result;
  assign data_out_o  = store_data;
  assign data_we_o   = lsu_data_we;
  assign data_re_o   = ex_mem_read_gated;

  // ==========================================================================
  // EX stage — WB mux (select write-back value before latching into EX/WB)
  // Priority: jump (link) > mem_to_reg (load) > alu_result
  // ==========================================================================

  logic [31:0] ex_write_data;

  always_comb begin
    // Default prevents latch inference (gotcha #1)
    ex_write_data = alu_result;
    if (ex_jump)
      ex_write_data = if_ex_pc_plus_4; // JAL/JALR: rd = return address PC+4
    else if (ex_mem_to_reg)
      ex_write_data = load_data;       // load: rd = sign/zero-extended data
    else
      ex_write_data = alu_result;      // arithmetic/logic: rd = ALU result
  end

  // ==========================================================================
  // EX stage — PC-next mux
  // Priority: taken branch > JAL > JALR > sequential (PC+4)
  // Mux is qualified by if_ex_valid: a bubble must not redirect the PC.
  // ==========================================================================

  always_comb begin
    // Default: sequential execution
    pc_next = pc_plus_4;
    if (ex_branch && branch_taken && if_ex_valid)
      pc_next = branch_target;           // taken branch: PC + B-imm
    else if (ex_jump && !ex_jalr && if_ex_valid)
      pc_next = alu_result;              // JAL: PC + J-imm (from ALU)
    else if (ex_jump && ex_jalr && if_ex_valid)
      pc_next = jalr_target;            // JALR: {(rs1+imm)[31:1], 1'b0}
    else
      pc_next = pc_plus_4;              // sequential
  end

  // ==========================================================================
  // EX stage — flush logic
  // Flush IF/EX register on any taken branch or any jump (1-cycle bubble).
  // Qualified by if_ex_valid to avoid double-flush on a bubble.
  // ==========================================================================

  assign flush_if_ex =
    ((ex_branch && branch_taken) || ex_jump) && if_ex_valid;

  // ==========================================================================
  // EX/WB pipeline register
  // reg_write is gated by if_ex_valid: bubbles must not write the regfile.
  // ==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wb_write_data <= 32'h0;
      wb_rd         <= 5'b0;
      wb_reg_write  <= 1'b0;
    end else begin
      wb_write_data <= ex_write_data;
      wb_rd         <= ex_rd_addr;
      wb_reg_write  <= ex_reg_write && if_ex_valid;
    end
  end

  // ==========================================================================
  // Halt output
  // Assert when a valid EX instruction is ECALL/EBREAK or illegal opcode.
  // ==========================================================================

  assign halt_o = (ex_halt || ex_illegal_instr || alu_ctrl_illegal) && if_ex_valid;

endmodule
