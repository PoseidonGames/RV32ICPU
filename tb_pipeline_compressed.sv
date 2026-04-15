// ============================================================================
// Module: tb_pipeline_compressed
// Description: Self-checking testbench for pipeline_top RV32C compressed
//   instruction support (M2c). Derives ALL expected values from
//   docs/canonical-reference.md §12. Tests 20 categories covering
//   the alignment buffer, all compressed instruction types, hazards,
//   and M1 regression compatibility.
// Author: Beaux Cable (Verification Agent)
// Date: April 2026
// Project: TSI RV32I Pipelined Processor (TSMC 180nm)
//
// Compressed encoding reference: canonical-reference.md §12.3-12.5
//   C0 (bits[1:0]=00): C.ADDI4SPN, C.LW, C.SW
//   C1 (bits[1:0]=01): C.NOP, C.ADDI, C.JAL, C.LI, C.LUI, C.ADDI16SP,
//                      C.SRLI, C.SRAI, C.ANDI, C.SUB, C.XOR, C.OR, C.AND,
//                      C.J, C.BEQZ, C.BNEZ
//   C2 (bits[1:0]=10): C.SLLI, C.LWSP, C.JR, C.MV, C.EBREAK, C.JALR,
//                      C.ADD, C.SWSP
//
// Packing rule (canonical-reference.md §12.6):
//   imem is word-indexed via instr_addr_o[9:2].
//   A compressed instr at byte-PC=N goes in imem[N/4][15:0] if N%4==0,
//   or imem[N/4][31:16] if N%4==2.
//   A 32-bit instr at byte-PC=N goes in imem[N/4][31:0] (N must be %4==0).
//
// Pipeline timing (canonical-reference.md §7.1):
//   Cycle 0: PC=addr, instruction fetched from imem.
//   Cycle 1: Instruction in EX stage.
//   Cycle 2: Result written to regfile (WB stage).
//   halt_o is TRANSIENT: asserted only during the cycle the instr is in EX.
// ============================================================================

`timescale 1ns/1ps

module tb_pipeline_compressed;

  // ==========================================================================
  // DUT ports
  // ==========================================================================
  logic        clk;
  logic        rst_n;
  logic [31:0] instr_addr_o;
  logic [31:0] instr_data_i;
  logic [31:0] data_addr_o;
  logic [31:0] data_out_o;
  logic [3:0]  data_we_o;
  logic        data_re_o;
  logic [31:0] data_in_i;
  logic        halt_o;

  // ==========================================================================
  // DUT instantiation
  // ==========================================================================
  pipeline_top dut (
    .clk          (clk),
    .rst_n        (rst_n),
    .instr_addr_o (instr_addr_o),
    .instr_data_i (instr_data_i),
    .data_addr_o  (data_addr_o),
    .data_out_o   (data_out_o),
    .data_we_o    (data_we_o),
    .data_re_o    (data_re_o),
    .data_in_i    (data_in_i),
    .halt_o       (halt_o)
  );

  // ==========================================================================
  // Memory models
  // ==========================================================================
  logic [31:0] imem [0:255]; // instruction memory (word-indexed)
  logic [7:0]  dmem [0:1023]; // data memory (byte array, 1 KiB)

  // Drive instruction memory (word-addressed by PC[9:2])
  assign instr_data_i = imem[instr_addr_o[9:2]];

  // Drive data read port
  assign data_in_i = {
    dmem[data_addr_o[9:0] + 3],
    dmem[data_addr_o[9:0] + 2],
    dmem[data_addr_o[9:0] + 1],
    dmem[data_addr_o[9:0]]
  };

  // Handle data memory writes via byte enables
  // (active-high AXI convention, canonical-reference.md §1.4)
  always_ff @(posedge clk) begin
    if (data_we_o[0]) dmem[data_addr_o[9:0]]     <= data_out_o[7:0];
    if (data_we_o[1]) dmem[data_addr_o[9:0] + 1] <= data_out_o[15:8];
    if (data_we_o[2]) dmem[data_addr_o[9:0] + 2] <= data_out_o[23:16];
    if (data_we_o[3]) dmem[data_addr_o[9:0] + 3] <= data_out_o[31:24];
  end

  // ==========================================================================
  // Clock: 10 ns half-period = 50 MHz
  // ==========================================================================
  initial clk = 1'b0;
  always #10 clk = ~clk;

  // ==========================================================================
  // Test counters
  // ==========================================================================
  integer pass_count;
  integer fail_count;

  // ==========================================================================
  // Helper tasks / functions
  // ==========================================================================

  task automatic check32(
    input string   test_name,
    input [31:0]   got,
    input [31:0]   expected
  );
    if (got !== expected) begin
      $display("FAIL  %s: got=0x%08X expected=0x%08X",
               test_name, got, expected);
      fail_count++;
    end else begin
      $display("PASS  %s: 0x%08X", test_name, got);
      pass_count++;
    end
  endtask

  task automatic check1(
    input string test_name,
    input        got,
    input        expected
  );
    if (got !== expected) begin
      $display("FAIL  %s: got=%b expected=%b",
               test_name, got, expected);
      fail_count++;
    end else begin
      $display("PASS  %s: %b", test_name, got);
      pass_count++;
    end
  endtask

  // Reset pipeline and memories.
  // Stimulus at negedge (gotcha #11 from docs/gotchas.md).
  // Assert rst_n=0 for 3 negedge cycles, deassert, #1.
  task automatic do_reset();
    integer i;
    for (i = 0; i < 256; i++) imem[i] = 32'h00000013; // NOP
    for (i = 0; i < 1024; i++) dmem[i] = 8'h00;
    @(negedge clk); rst_n = 1'b0;
    @(negedge clk);
    @(negedge clk);
    @(negedge clk); rst_n = 1'b1;
    #1;
  endtask

  // Run N clock cycles then settle for #1
  task automatic run_cycles(input integer n);
    integer i;
    for (i = 0; i < n; i++) @(posedge clk);
    #1;
  endtask

  // Read a word from dmem at byte address
  function automatic [31:0] dmem_word(input [9:0] byte_addr);
    dmem_word = {dmem[byte_addr+3], dmem[byte_addr+2],
                 dmem[byte_addr+1], dmem[byte_addr]};
  endfunction

  // ==========================================================================
  // 32-bit instruction encoding helpers
  // (canonical-reference.md §3)
  // ==========================================================================

  localparam [6:0] OP_R    = 7'b0110011;
  localparam [6:0] OP_IALU = 7'b0010011;
  localparam [6:0] OP_LOAD = 7'b0000011;
  localparam [6:0] OP_STOR = 7'b0100011;
  localparam [6:0] OP_BRNC = 7'b1100011;
  localparam [6:0] OP_JAL  = 7'b1101111;
  localparam [6:0] OP_JALR = 7'b1100111;
  localparam [6:0] OP_LUI  = 7'b0110111;
  localparam [6:0] OP_AUIPC= 7'b0010111;
  localparam [6:0] OP_SYS  = 7'b1110011;

  localparam [31:0] NOP32  = 32'h00000013; // ADDI x0,x0,0

  function automatic [31:0] enc_r(
    input [6:0] funct7,
    input [4:0] rs2, rs1,
    input [2:0] funct3,
    input [4:0] rd,
    input [6:0] opcode
  );
    enc_r = {funct7, rs2, rs1, funct3, rd, opcode};
  endfunction

  function automatic [31:0] enc_i(
    input [11:0] imm,
    input [4:0]  rs1,
    input [2:0]  funct3,
    input [4:0]  rd,
    input [6:0]  opcode
  );
    enc_i = {imm, rs1, funct3, rd, opcode};
  endfunction

  function automatic [31:0] enc_s(
    input [11:0] imm,
    input [4:0]  rs2, rs1,
    input [2:0]  funct3,
    input [6:0]  opcode
  );
    enc_s = {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
  endfunction

  function automatic [31:0] enc_b(
    input [12:0] imm,
    input [4:0]  rs2, rs1,
    input [2:0]  funct3,
    input [6:0]  opcode
  );
    enc_b = {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], opcode};
  endfunction

  function automatic [31:0] enc_u(
    input [19:0] imm_upper,
    input [4:0]  rd,
    input [6:0]  opcode
  );
    enc_u = {imm_upper, rd, opcode};
  endfunction

  function automatic [31:0] enc_j(
    input [20:0] imm,
    input [4:0]  rd,
    input [6:0]  opcode
  );
    enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode};
  endfunction

  // ==========================================================================
  // Compressed 16-bit instruction encoding helpers
  // All bit positions from canonical-reference.md §12.3-12.5.
  // ==========================================================================

  // C.NOP = {3'b000, 1'b0, 5'b00000, 5'b00000, 2'b01} = 16'h0001
  localparam [15:0] C_NOP = 16'h0001;

  // C.ADDI rd, sext(nzimm) — C1 funct3=000
  // {3'b000, nzimm[5], rd[4:0], nzimm[4:0], 2'b01}
  function automatic [15:0] enc_c_addi(
    input [4:0] rd,
    input [5:0] nzimm  // 6-bit signed
  );
    enc_c_addi = {3'b000, nzimm[5], rd, nzimm[4:0], 2'b01};
  endfunction

  // C.LI rd, sext(imm) — C1 funct3=010
  // {3'b010, imm[5], rd[4:0], imm[4:0], 2'b01}
  function automatic [15:0] enc_c_li(
    input [4:0] rd,
    input [5:0] imm   // 6-bit signed
  );
    enc_c_li = {3'b010, imm[5], rd, imm[4:0], 2'b01};
  endfunction

  // C.LUI rd, nzimm — C1 funct3=011, rd != x0 and rd != x2
  // nzimm occupies bits[17:12] of the LUI immediate.
  // Encoding: {3'b011, nzimm[17], rd[4:0], nzimm[16:12], 2'b01}
  // (canonical-reference.md §12.4: nzimm[5] = inst[12], nzimm[4:0] = inst[6:2])
  function automatic [15:0] enc_c_lui(
    input [4:0] rd,
    input [5:0] nzimm  // bits[17:12] of the upper-imm (6-bit, nonzero)
  );
    enc_c_lui = {3'b011, nzimm[5], rd, nzimm[4:0], 2'b01};
  endfunction

  // C.ADDI16SP nzimm — C1 funct3=011, rd=x2
  // nzimm scaled x16 (9-bit signed, bits [9:4]).
  // inst[12]=nzimm[9], inst[4:3]=nzimm[8:7], inst[5]=nzimm[6],
  // inst[2]=nzimm[5], inst[6]=nzimm[4]
  // Encoding: {3'b011, nzimm[9], 5'b00010, nzimm[4], nzimm[6],
  //            nzimm[8:7], nzimm[5], 2'b01}
  // nzimm_in is the 10-bit signed immediate (multiple of 16, nonzero).
  function automatic [15:0] enc_c_addi16sp(
    input [9:0] nzimm  // signed, multiple of 16 (bits [9:4] significant)
  );
    enc_c_addi16sp = {3'b011, nzimm[9], 5'b00010,
                      nzimm[4], nzimm[6], nzimm[8:7], nzimm[5],
                      2'b01};
  endfunction

  // C.ADDI4SPN rd', nzuimm — C0 funct3=000
  // nzuimm = {inst[10:7], inst[12:11], inst[5], inst[6], 2'b00}
  // so inst[10:7]=nzuimm[9:6], inst[12:11]=nzuimm[5:4],
  //    inst[5]=nzuimm[3], inst[6]=nzuimm[2]
  // Encoding: {3'b000, nzuimm[5:4], nzuimm[9:6], nzuimm[2], nzuimm[3],
  //            rd'[2:0], 2'b00}
  // nzuimm_in is the 10-bit zero-extended immediate (multiple of 4, nonzero).
  function automatic [15:0] enc_c_addi4spn(
    input [2:0] rd_p,    // compact register (x8..x15)
    input [9:0] nzuimm   // zero-extended multiple-of-4
  );
    enc_c_addi4spn = {3'b000, nzuimm[5:4], nzuimm[9:6],
                      nzuimm[2], nzuimm[3], rd_p, 2'b00};
  endfunction

  // C.LW rd', uimm(rs1') — C0 funct3=010
  // uimm = {inst[5], inst[12:10], inst[6], 2'b00}
  // inst[12:10]=uimm[5:3], inst[6]=uimm[2], inst[5]=uimm[6]
  // Encoding: {3'b010, uimm[5:3], rs1'[2:0], uimm[2], uimm[6], rd'[2:0], 2'b00}
  function automatic [15:0] enc_c_lw(
    input [2:0] rd_p,
    input [2:0] rs1_p,
    input [6:0] uimm    // zero-ext, multiple of 4, bits[6:2] meaningful
  );
    enc_c_lw = {3'b010, uimm[5:3], rs1_p, uimm[2], uimm[6], rd_p, 2'b00};
  endfunction

  // C.SW rs2', uimm(rs1') — C0 funct3=110, same offset encoding as C.LW
  function automatic [15:0] enc_c_sw(
    input [2:0] rs2_p,
    input [2:0] rs1_p,
    input [6:0] uimm
  );
    enc_c_sw = {3'b110, uimm[5:3], rs1_p, uimm[2], uimm[6], rs2_p, 2'b00};
  endfunction

  // C.LWSP rd, uimm(x2) — C2 funct3=010
  // uimm = {inst[3:2], inst[12], inst[6:4], 2'b00}
  // inst[12]=uimm[5], inst[6:4]=uimm[4:2], inst[3:2]=uimm[7:6]
  // Encoding: {3'b010, uimm[5], rd[4:0], uimm[4:2], uimm[7:6], 2'b10}
  function automatic [15:0] enc_c_lwsp(
    input [4:0] rd,
    input [7:0] uimm    // zero-ext, multiple of 4
  );
    enc_c_lwsp = {3'b010, uimm[5], rd, uimm[4:2], uimm[7:6], 2'b10};
  endfunction

  // C.SWSP rs2, uimm(x2) — C2 funct3=110
  // uimm = {inst[8:7], inst[12:9], 2'b00}
  // inst[12:9]=uimm[5:2], inst[8:7]=uimm[7:6]
  // Encoding: {3'b110, uimm[5:2], uimm[7:6], rs2[4:0], 2'b10}
  function automatic [15:0] enc_c_swsp(
    input [4:0] rs2,
    input [7:0] uimm    // zero-ext, multiple of 4
  );
    enc_c_swsp = {3'b110, uimm[5:2], uimm[7:6], rs2, 2'b10};
  endfunction

  // C.JAL imm — C1 funct3=001 (RV32 only), link x1
  // imm = {inst[12], inst[8], inst[10:9], inst[6], inst[7], inst[2],
  //        inst[11], inst[5:3], 1'b0}  (12-bit signed, ±2KiB)
  // inst[12]=imm[11], inst[11]=imm[4], inst[10:9]=imm[9:8],
  // inst[8]=imm[10], inst[7]=imm[6], inst[6]=imm[7],    <- NOTE: swapped
  // inst[5:3]=imm[3:1], inst[2]=imm[5]
  // Encoding: {3'b001, imm[11], imm[4], imm[9:8], imm[10], imm[6],
  //            imm[7], imm[3:1], imm[5], 2'b01}
  function automatic [15:0] enc_c_jal(
    input [11:0] imm   // 12-bit signed (bit 0 always 0)
  );
    enc_c_jal = {3'b001, imm[11], imm[4], imm[9:8], imm[10],
                 imm[6], imm[7], imm[3:1], imm[5], 2'b01};
  endfunction

  // C.J imm — C1 funct3=101 (JAL x0), same immediate encoding
  function automatic [15:0] enc_c_j(
    input [11:0] imm
  );
    enc_c_j = {3'b101, imm[11], imm[4], imm[9:8], imm[10],
               imm[6], imm[7], imm[3:1], imm[5], 2'b01};
  endfunction

  // C.BEQZ rs1', offset — C1 funct3=110
  // off = {inst[12], inst[6:5], inst[2], inst[11:10], inst[4:3], 1'b0}
  // inst[12]=off[8], inst[11:10]=off[4:3], inst[6:5]=off[7:6],
  // inst[4:3]=off[2:1], inst[2]=off[5]
  // Encoding: {3'b110, off[8], off[4:3], rs1'[2:0],
  //            off[7:6], off[2:1], off[5], 2'b01}
  function automatic [15:0] enc_c_beqz(
    input [2:0] rs1_p,
    input [8:0] off    // 9-bit signed (bit 0 always 0)
  );
    enc_c_beqz = {3'b110, off[8], off[4:3], rs1_p,
                  off[7:6], off[2:1], off[5], 2'b01};
  endfunction

  // C.BNEZ rs1', offset — C1 funct3=111 (same as BEQZ encoding)
  function automatic [15:0] enc_c_bnez(
    input [2:0] rs1_p,
    input [8:0] off
  );
    enc_c_bnez = {3'b111, off[8], off[4:3], rs1_p,
                  off[7:6], off[2:1], off[5], 2'b01};
  endfunction

  // C.SRLI rd', shamt — C1 funct3=100, inst[11:10]=00
  // Encoding: {3'b100, 1'b0, 2'b00, rd'[2:0], shamt[4:0], 2'b01}
  function automatic [15:0] enc_c_srli(
    input [2:0] rd_p,
    input [4:0] shamt
  );
    enc_c_srli = {3'b100, 1'b0, 2'b00, rd_p, shamt, 2'b01};
  endfunction

  // C.SRAI rd', shamt — C1 funct3=100, inst[11:10]=01
  // Encoding: {3'b100, 1'b0, 2'b01, rd'[2:0], shamt[4:0], 2'b01}
  function automatic [15:0] enc_c_srai(
    input [2:0] rd_p,
    input [4:0] shamt
  );
    enc_c_srai = {3'b100, 1'b0, 2'b01, rd_p, shamt, 2'b01};
  endfunction

  // C.ANDI rd', sext(imm) — C1 funct3=100, inst[11:10]=10
  // Encoding: {3'b100, imm[5], 2'b10, rd'[2:0], imm[4:0], 2'b01}
  function automatic [15:0] enc_c_andi(
    input [2:0] rd_p,
    input [5:0] imm    // 6-bit signed
  );
    enc_c_andi = {3'b100, imm[5], 2'b10, rd_p, imm[4:0], 2'b01};
  endfunction

  // C.SUB rd', rs2' — C1 funct3=100, inst[11:10]=11, inst[12]=0, inst[6:5]=00
  // Encoding: {3'b100, 1'b0, 2'b11, rd'[2:0], 2'b00, rs2'[2:0], 2'b01}
  function automatic [15:0] enc_c_sub(
    input [2:0] rd_p,
    input [2:0] rs2_p
  );
    enc_c_sub = {3'b100, 1'b0, 2'b11, rd_p, 2'b00, rs2_p, 2'b01};
  endfunction

  // C.XOR rd', rs2' — inst[6:5]=01
  // Encoding: {3'b100, 1'b0, 2'b11, rd'[2:0], 2'b01, rs2'[2:0], 2'b01}
  function automatic [15:0] enc_c_xor(
    input [2:0] rd_p,
    input [2:0] rs2_p
  );
    enc_c_xor = {3'b100, 1'b0, 2'b11, rd_p, 2'b01, rs2_p, 2'b01};
  endfunction

  // C.OR rd', rs2' — inst[6:5]=10
  function automatic [15:0] enc_c_or(
    input [2:0] rd_p,
    input [2:0] rs2_p
  );
    enc_c_or = {3'b100, 1'b0, 2'b11, rd_p, 2'b10, rs2_p, 2'b01};
  endfunction

  // C.AND rd', rs2' — inst[6:5]=11
  function automatic [15:0] enc_c_and(
    input [2:0] rd_p,
    input [2:0] rs2_p
  );
    enc_c_and = {3'b100, 1'b0, 2'b11, rd_p, 2'b11, rs2_p, 2'b01};
  endfunction

  // C.SLLI rd, shamt — C2 funct3=000
  // Encoding: {3'b000, 1'b0, rd[4:0], shamt[4:0], 2'b10}
  function automatic [15:0] enc_c_slli(
    input [4:0] rd,
    input [4:0] shamt
  );
    enc_c_slli = {3'b000, 1'b0, rd, shamt, 2'b10};
  endfunction

  // C.MV rd, rs2 — C2 funct3=100, inst[12]=0, rs2 != 0
  // Encoding: {3'b100, 1'b0, rd[4:0], rs2[4:0], 2'b10}
  function automatic [15:0] enc_c_mv(
    input [4:0] rd,
    input [4:0] rs2
  );
    enc_c_mv = {3'b100, 1'b0, rd, rs2, 2'b10};
  endfunction

  // C.ADD rd, rs2 — C2 funct3=100, inst[12]=1, rs2 != 0
  // Encoding: {3'b100, 1'b1, rd[4:0], rs2[4:0], 2'b10}
  function automatic [15:0] enc_c_add(
    input [4:0] rd,
    input [4:0] rs2
  );
    enc_c_add = {3'b100, 1'b1, rd, rs2, 2'b10};
  endfunction

  // C.JR rs1 — C2 funct3=100, inst[12]=0, rs2=0, rs1 != 0
  // Encoding: {3'b100, 1'b0, rs1[4:0], 5'b00000, 2'b10}
  function automatic [15:0] enc_c_jr(
    input [4:0] rs1
  );
    enc_c_jr = {3'b100, 1'b0, rs1, 5'b00000, 2'b10};
  endfunction

  // C.JALR rs1 — C2 funct3=100, inst[12]=1, rs2=0, rs1 != 0
  // Encoding: {3'b100, 1'b1, rs1[4:0], 5'b00000, 2'b10}
  function automatic [15:0] enc_c_jalr(
    input [4:0] rs1
  );
    enc_c_jalr = {3'b100, 1'b1, rs1, 5'b00000, 2'b10};
  endfunction

  // C.EBREAK — C2 funct3=100, inst[12]=1, rs1=0, rs2=0
  // = {3'b100, 1'b1, 5'b00000, 5'b00000, 2'b10} = 16'h9002
  localparam [15:0] C_EBREAK = 16'h9002;

  // ==========================================================================
  // Packing helpers
  // lower half = bits[15:0], upper half = bits[31:16]
  // ==========================================================================

  // Two compressed instructions in one imem word
  task automatic pack_hh(
    input integer word_idx,
    input [15:0] lo,   // goes to bits[15:0] (byte PC = word_idx*4)
    input [15:0] hi    // goes to bits[31:16] (byte PC = word_idx*4+2)
  );
    imem[word_idx] = {hi, lo};
  endtask

  // One 32-bit instruction at a word index
  task automatic pack_w(
    input integer word_idx,
    input [31:0] instr
  );
    imem[word_idx] = instr;
  endtask

  // One compressed instruction in lower half, NOP16 filler in upper half
  task automatic pack_h_lo(
    input integer word_idx,
    input [15:0] lo
  );
    imem[word_idx] = {C_NOP, lo};
  endtask

  // One compressed instruction in upper half, NOP16 filler in lower half
  task automatic pack_h_hi(
    input integer word_idx,
    input [15:0] hi
  );
    imem[word_idx] = {hi, C_NOP};
  endtask

  // ==========================================================================
  // TEST SUITE
  // ==========================================================================
  initial begin
    pass_count = 0;
    fail_count = 0;

    // ========================================================================
    // TEST 1: C.NOP STREAM
    // Spec §12.4: C.NOP = ADDI x0,x0,0 compressed.
    // C.NOP = {3'b000, 1'b0, 5'b00000, 5'b00000, 2'b01} = 16'h0001
    // PC advances by 2 per C.NOP (canonical-reference.md §12.6:
    //   is_compressed = (selected_hw[1:0] != 2'b11) → pc_increment = pc+2).
    // Expected: halt_o stays 0, no dmem writes, PC word-aligned throughout.
    // ========================================================================
    $display("\n--- TEST 1: C.NOP stream ---");
    do_reset();
    // Fill imem with C.NOP pairs (two per 32-bit word)
    begin : cnop_fill
      integer i;
      for (i = 0; i < 64; i++) imem[i] = {C_NOP, C_NOP};
    end
    run_cycles(5);
    check1("C.NOP stream: halt_o=0", halt_o, 1'b0);
    if (instr_addr_o[1:0] !== 2'b00) begin
      $display("FAIL  C.NOP stream: PC not word-aligned: 0x%08X",
               instr_addr_o);
      fail_count++;
    end else begin
      $display("PASS  C.NOP stream: PC word-aligned 0x%08X",
               instr_addr_o);
      pass_count++;
    end
    run_cycles(5);
    check1("C.NOP stream: halt_o still 0 after 10 cycles", halt_o, 1'b0);
    check32("C.NOP stream: no spurious dmem write (data_we_o=0)",
            {28'h0, data_we_o}, 32'h0);

    // ========================================================================
    // TEST 2: MIXED 16/32-BIT SEQUENCE
    // Spec §12.4, §1.1:
    //   PC=0: C.LI x10, 5  → x10 = sext(5) = 5
    //         Encoding: enc_c_li(x10=10, 6'd5)
    //   PC=2: C.LI x11, 3  → x11 = 3
    //   PC=4: ADD x12,x10,x11 → x12 = 5+3 = 8
    // After ADD writeback, SW x12 to dmem and verify 8.
    //
    // Packing:
    //   imem[0]: {C.LI x11,3 [31:16], C.LI x10,5 [15:0]}
    //   imem[1]: ADD x12,x10,x11  (32-bit, PC=4)
    //   imem[2]: SW x12,0x200(x0) (32-bit, PC=8)
    // ========================================================================
    $display("\n--- TEST 2: Mixed 16/32-bit sequence ---");
    do_reset();
    pack_hh(0, enc_c_li(5'd10, 6'd5),  enc_c_li(5'd11, 6'd3));
    pack_w (1, enc_r(7'b0000000, 5'd11, 5'd10, 3'b000, 5'd12, OP_R));
    pack_w (2, enc_s(12'h200, 5'd12, 5'd0, 3'b010, OP_STOR));
    // Drain: PC=12 onward is NOP32. Pipeline: C.LI x10 in EX at cyc1,
    //   WB at cyc2; C.LI x11 EX at cyc2, WB at cyc3; ADD EX at cyc3
    //   (needs x10,x11 — both written at cyc2/cyc3 with forwarding), WB at cyc4.
    //   SW at imem[2] (PC=8): ADD at PC=4 finishes WB at cyc4; SW EX at cyc5.
    //   Allow extra drain cycles.
    run_cycles(12);
    // Spec §1.1: ADD rd = rs1+rs2 = 5+3 = 8
    check32("Mixed 16/32: ADD x12,x10,x11 (5+3) -> 8",
            dmem_word(10'h200), 32'h00000008);

    // ========================================================================
    // TEST 3: STRADDLING 32-BIT INSTRUCTION
    // A compressed instruction is at PC=0 (imem[0][15:0]).
    // A 32-bit instruction straddles: its lower 16 bits sit in imem[0][31:16]
    // and its upper 16 bits sit in imem[1][15:0].
    //
    // Spec §12.6: alignment buffer holds upper halfword. When upper_valid=1 and
    //   the held halfword has bits[1:0]==11, the next fetch supplies the upper
    //   half of the 32-bit instruction.
    //
    // Program:
    //   PC=0: C.LI x10, 7   (compressed, imem[0][15:0])
    //   PC=2: ADDI x11,x0,4 (32-bit, lower half in imem[0][31:16],
    //                        upper half in imem[1][15:0])
    //   PC=6: SW x11,0x200(x0) (32-bit, imem[1][31:16] lower +
    //                            imem[2][15:0] upper)
    //         Actually to keep it simple, place SW at PC=6 which straddles
    //         imem[1][31:16] and imem[2][15:0].
    //
    // ADDI x11,x0,4 = enc_i(12'd4, 5'd0, 3'b000, 5'd11, OP_IALU)
    // Lower 16 bits [15:0] go in imem[0][31:16]
    // Upper 16 bits [31:16] go in imem[1][15:0]
    //
    // SW x11,0x200(x0) = enc_s(12'h200, 5'd11, 5'd0, 3'b010, OP_STOR)
    // Lower 16 bits [15:0] go in imem[1][31:16]
    // Upper 16 bits [31:16] go in imem[2][15:0]
    //
    // Expected: x11 = 4 (ADDI executed correctly despite straddle).
    // ========================================================================
    $display("\n--- TEST 3: Straddling 32-bit instruction ---");
    do_reset();
    begin : straddle_blk
      logic [31:0] addi_x11;
      logic [31:0] sw_x11;
      addi_x11 = enc_i(12'd4, 5'd0, 3'b000, 5'd11, OP_IALU);
      sw_x11   = enc_s(12'h200, 5'd11, 5'd0, 3'b010, OP_STOR);
      // imem[0][15:0]  = C.LI x10,7
      // imem[0][31:16] = addi_x11[15:0]
      imem[0] = {addi_x11[15:0], enc_c_li(5'd10, 6'd7)};
      // imem[1][15:0]  = addi_x11[31:16]
      // imem[1][31:16] = sw_x11[15:0]
      imem[1] = {sw_x11[15:0], addi_x11[31:16]};
      // imem[2][15:0]  = sw_x11[31:16]
      imem[2] = {16'h0001, sw_x11[31:16]}; // upper: C.NOP filler
    end
    run_cycles(14);
    // Spec §1.2: ADDI x11,x0,4 -> x11=4; SW stores it to dmem[0x200]
    check32("Straddle 32-bit ADDI x11,x0,4 -> dmem[0x200]=4",
            dmem_word(10'h200), 32'h00000004);

    // ========================================================================
    // TEST 4: C.JAL RETURN ADDRESS = PC+2
    // Spec §12.4: C.JAL = JAL x1, sext(imm). The link address stored in x1
    //   is PC+2 (NOT PC+4) because the instruction is only 2 bytes.
    // Spec §12.6: if_ex_pc_plus_n = PC+2 for compressed instructions.
    //
    // Program:
    //   PC=0: C.JAL +4  → x1 = 0+2 = 2; PC → 0+4 = 4
    //         (imm=4, forward jump of 4 bytes)
    //   (PC=2: would be bubble from flush — not in path)
    //   PC=4: SW x1, 0x200(x0) → stores link address
    //
    // C.JAL imm=4: enc_c_jal(12'd4)
    // Packing:
    //   imem[0][15:0] = C.JAL +4
    //   imem[0][31:16]= C.NOP (flush bubble, not executed)
    //   imem[1]       = SW x1,0x200(x0)
    //
    // Expected: dmem[0x200] = 2 (PC+2 = 0+2)
    // ========================================================================
    $display("\n--- TEST 4: C.JAL return address = PC+2 ---");
    do_reset();
    pack_hh(0, enc_c_jal(12'd4), C_NOP);  // C.JAL@PC=0, NOP@PC=2(flushed)
    pack_w (1, enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR)); // SW x1@PC=4
    pack_w (2, NOP32);
    pack_w (3, NOP32);
    pack_w (4, NOP32);
    run_cycles(10);
    // Spec: C.JAL at PC=0 → link x1 = PC+2 = 2
    check32("C.JAL link addr = PC+2 = 2",
            dmem_word(10'h200), 32'h00000002);

    // ========================================================================
    // TEST 5: C.J FORWARD AND BACKWARD
    // Spec §12.4: C.J = JAL x0, sext(imm). Unconditional jump, no link.
    //
    // 5a: Forward jump
    //   PC=0: C.J +8  → PC=8
    //   PC=2: C.LI x5,99 (flushed — 1-cycle bubble)
    //   PC=8: C.LI x6,42 → x6=42
    //   Then SW x6,0x200(x0)
    //
    // 5b: Backward jump (loop executed once then forward exit)
    //   PC=0: C.LI x7,10   → x7=10
    //   PC=2: C.J +6        → PC=8
    //   PC=4: C.LI x7,99 (flushed)
    //   PC=8: SW x7,0x200(x0) → stores 10
    //
    // C.J imm=+8: enc_c_j(12'd8)
    // C.J imm=+6: enc_c_j(12'd6)
    // ========================================================================
    $display("\n--- TEST 5a: C.J forward jump ---");
    do_reset();
    // imem[0][15:0] = C.J +8, imem[0][31:16] = C.LI x5,29 (flushed)
    pack_hh(0, enc_c_j(12'd8), enc_c_li(5'd5, 6'd29));
    // PC=4 (imem[1]) = NOP (not in path)
    // PC=8 (imem[2]) = C.LI x6,25
    pack_h_lo(2, enc_c_li(5'd6, 6'd25));
    pack_w(3, enc_s(12'h200, 5'd6, 5'd0, 3'b010, OP_STOR));
    pack_w(4, NOP32); pack_w(5, NOP32);
    run_cycles(12);
    // Spec: C.LI x6,25 → x6=25; SW stores 25
    check32("C.J forward: x6=25", dmem_word(10'h200), 32'h00000019);

    $display("\n--- TEST 5b: C.J from PC=2 (upper half) ---");
    do_reset();
    // imem[0][15:0] = C.LI x7,10 (PC=0)
    // imem[0][31:16]= C.J +6    (PC=2 → target PC=2+6=8)
    pack_hh(0, enc_c_li(5'd7, 6'd10), enc_c_j(12'd6));
    // imem[1][15:0] = C.LI x7,99 (PC=4, flushed bubble)
    pack_h_lo(1, enc_c_li(5'd7, 6'd29));
    // PC=8: SW x7,0x200(x0)
    pack_w(2, enc_s(12'h200, 5'd7, 5'd0, 3'b010, OP_STOR));
    pack_w(3, NOP32); pack_w(4, NOP32);
    run_cycles(12);
    // Spec: x7=10 from C.LI; C.J jumps past sentinel C.LI x7,99
    check32("C.J from upper half: x7=10", dmem_word(10'h200), 32'h0000000A);

    // ========================================================================
    // TEST 6: C.BEQZ / C.BNEZ TAKEN AND NOT-TAKEN
    // Spec §12.4: C.BEQZ = BEQ rs1',x0,offset; C.BNEZ = BNE rs1',x0,offset.
    // Compact register rs1' maps to x8..x15 per §12.2.
    //
    // 6a: C.BEQZ with rs1'=x8 (x8=0) → taken
    //   PC=0: C.LI x8,0   (x8=0; compact reg 0 = x8)
    //   PC=2: C.BEQZ x8,+6 → taken (x8==0), PC→2+6=8
    //   PC=4: C.LI x9,99 (flushed bubble)
    //   PC=8: C.LI x9,7
    //   Store x9 → expect 7
    //
    // 6b: C.BEQZ not taken (rs1'=x8, x8=5 ≠ 0)
    //   PC=0: C.LI x8,5
    //   PC=2: C.BEQZ x8,+6 → not taken
    //   PC=4: C.LI x9,77
    //   Store x9 → expect 77
    //
    // 6c: C.BNEZ taken (rs1'=x8, x8=5 ≠ 0)
    // 6d: C.BNEZ not taken (rs1'=x8, x8=0)
    //
    // C.BEQZ/BNEZ rs1'=3'b000 → x8
    // ========================================================================
    $display("\n--- TEST 6a: C.BEQZ taken (x8=0) ---");
    do_reset();
    // PC=0: C.LI x8,0; PC=2: C.BEQZ x8,+6
    pack_hh(0, enc_c_li(5'd8, 6'd0),
               enc_c_beqz(3'b000, 9'd6));
    // PC=4: C.LI x9,99 (flushed)
    pack_h_lo(1, enc_c_li(5'd9, 6'd29));
    // PC=8: C.LI x9,7
    pack_h_lo(2, enc_c_li(5'd9, 6'd7));
    pack_w(3, enc_s(12'h200, 5'd9, 5'd0, 3'b010, OP_STOR));
    pack_w(4, NOP32); pack_w(5, NOP32);
    run_cycles(12);
    // Spec: x8=0, BEQ taken → x9=7
    check32("C.BEQZ taken (x8=0): x9=7",
            dmem_word(10'h200), 32'h00000007);

    $display("\n--- TEST 6b: C.BEQZ not taken (x8=5) ---");
    do_reset();
    pack_hh(0, enc_c_li(5'd8, 6'd5),
               enc_c_beqz(3'b000, 9'd6));
    // PC=4 (not taken → falls through here): C.LI x9,23
    pack_h_lo(1, enc_c_li(5'd9, 6'd23));
    pack_w(2, enc_s(12'h200, 5'd9, 5'd0, 3'b010, OP_STOR));
    pack_w(3, NOP32); pack_w(4, NOP32);
    run_cycles(12);
    // Spec: x8=5≠0, BEQ not taken → x9=23
    check32("C.BEQZ not taken (x8=5): x9=23",
            dmem_word(10'h200), 32'h00000017);

    $display("\n--- TEST 6c: C.BNEZ taken (x8=5) ---");
    do_reset();
    pack_hh(0, enc_c_li(5'd8, 6'd5),
               enc_c_bnez(3'b000, 9'd6));
    // PC=4: C.LI x9,29 (flushed)
    pack_h_lo(1, enc_c_li(5'd9, 6'd29));
    // PC=8: C.LI x9,19
    pack_h_lo(2, enc_c_li(5'd9, 6'd19));
    pack_w(3, enc_s(12'h200, 5'd9, 5'd0, 3'b010, OP_STOR));
    pack_w(4, NOP32); pack_w(5, NOP32);
    run_cycles(12);
    // Spec: x8=5≠0, BNE taken → x9=19
    check32("C.BNEZ taken (x8=5): x9=19",
            dmem_word(10'h200), 32'h00000013);

    $display("\n--- TEST 6d: C.BNEZ not taken (x8=0) ---");
    do_reset();
    pack_hh(0, enc_c_li(5'd8, 6'd0),
               enc_c_bnez(3'b000, 9'd6));
    // PC=4: C.LI x9,21 (falls through)
    pack_h_lo(1, enc_c_li(5'd9, 6'd21));
    pack_w(2, enc_s(12'h200, 5'd9, 5'd0, 3'b010, OP_STOR));
    pack_w(3, NOP32); pack_w(4, NOP32);
    run_cycles(12);
    // Spec: x8=0, BNE not taken → x9=21
    check32("C.BNEZ not taken (x8=0): x9=21",
            dmem_word(10'h200), 32'h00000015);

    // ========================================================================
    // TEST 7: BRANCH INTO MIDDLE OF WORD (PC[1]=1 target)
    // Branch target at byte PC=6 (imem[1][31:16] — upper half of word 1).
    // The pipeline must fetch imem[1] and use the upper halfword.
    // Spec §12.6: instr_addr_o = word-aligned; alignment buffer selects
    //   upper_buf or current lower half based on upper_valid.
    //
    // Program:
    //   PC=0: C.LI x10,0 (x10=0)
    //   PC=2: C.BEQZ x10,+4 → taken (x10=0), PC→2+4=6
    //   PC=4: C.LI x11,99 (flushed bubble)
    //   PC=6: C.LI x11,22  ← target is upper half of imem[1]
    //   Store x11 → expect 22
    //
    // Packing:
    //   imem[0]: {C.BEQZ x10,+4 [31:16], C.LI x10,0 [15:0]}
    //   imem[1]: {C.LI x11,22  [31:16],  C.LI x11,99 [15:0]}
    //   imem[2]: SW x11 word
    //
    // C.BEQZ rs1'=3'b010 maps to x10. offset=4.
    // ========================================================================
    $display("\n--- TEST 7: Branch into upper half of word (PC[1]=1) ---");
    do_reset();
    pack_hh(0, enc_c_li(5'd10, 6'd0),
               enc_c_beqz(3'b010, 9'd4));
    pack_hh(1, enc_c_li(5'd11, 6'd29),   // PC=4 (flushed bubble slot)
               enc_c_li(5'd11, 6'd22));   // PC=6 (branch target)
    pack_w (2, enc_s(12'h200, 5'd11, 5'd0, 3'b010, OP_STOR));
    pack_w (3, NOP32); pack_w(4, NOP32);
    run_cycles(12);
    // Spec: branch taken to PC=6 (upper half), x11=22
    check32("Branch to upper half of word: x11=22",
            dmem_word(10'h200), 32'h00000016);

    // ========================================================================
    // TEST 8: C.LWSP / C.SWSP ROUND-TRIP
    // Spec §12.5:
    //   C.SWSP rs2, uimm(x2) = SW rs2, uimm(x2)
    //   C.LWSP rd, uimm(x2)  = LW rd, uimm(x2)
    // x2 = stack pointer. We set x2 to a known dmem address (e.g., 0x300),
    // store a value via C.SWSP, load it back via C.LWSP, verify round-trip.
    //
    // uimm for C.SWSP/C.LWSP is zero-extended, scaled x4.
    // Use uimm=0 (offset 0 from x2=0x300 → dmem[0x300]).
    //
    // Program (32-bit instructions used to set up x2, x5):
    //   ADDI x2, x0, 0x300   → x2=0x300 (stack pointer)
    //   ADDI x5, x0, 0xAB    → x5=0xAB
    //   C.SWSP x5, 0(x2)     → dmem[0x300]=0xAB
    //   C.LWSP x6, 0(x2)     → x6 = dmem[0x300] = 0xAB
    //   SW x6, 0x200(x0)     → verify x6=0xAB
    //
    // Packing (32-bit setup, then compressed):
    //   imem[0] = ADDI x2,x0,0x300  (PC=0)
    //   imem[1] = ADDI x5,x0,0xAB   (PC=4)
    //   imem[2][15:0]  = C.SWSP x5, uimm=0 (PC=8)
    //   imem[2][31:16] = C.LWSP x6, uimm=0 (PC=10)
    //   imem[3] = SW x6,0x200(x0)   (PC=12)
    // ========================================================================
    $display("\n--- TEST 8: C.LWSP / C.SWSP round-trip ---");
    do_reset();
    pack_w(0, enc_i(12'h300, 5'd0, 3'b000, 5'd2, OP_IALU));   // ADDI x2,x0,0x300
    pack_w(1, enc_i(12'hAB,  5'd0, 3'b000, 5'd5, OP_IALU));   // ADDI x5,x0,0xAB
    pack_hh(2, enc_c_swsp(5'd5, 8'd0),   // C.SWSP x5, 0(x2) @ PC=8
               enc_c_lwsp(5'd6, 8'd0));  // C.LWSP x6, 0(x2) @ PC=10
    pack_w(3, enc_s(12'h200, 5'd6, 5'd0, 3'b010, OP_STOR));   // SW x6,0x200(x0)
    pack_w(4, NOP32); pack_w(5, NOP32); pack_w(6, NOP32);
    run_cycles(14);
    // Spec: C.SWSP stores 0xAB to dmem[0x300]; C.LWSP loads it back; x6=0xAB
    check32("C.LWSP/C.SWSP round-trip: x6=0xAB",
            dmem_word(10'h200), 32'h000000AB);

    // ========================================================================
    // TEST 9: C.LW / C.SW ROUND-TRIP
    // Spec §12.3:
    //   C.SW rs2',uimm(rs1') = SW rs2',uimm(rs1')
    //   C.LW rd',uimm(rs1')  = LW rd',uimm(rs1')
    // Compact registers rd'/rs1'/rs2' ∈ x8..x15 (§12.2).
    //
    // Use x8 as base pointer, x9 as store data, x10 as load destination.
    // x8=0x400, x9=0xBEEF, uimm=0 → dmem[0x400]
    //
    // Program:
    //   ADDI x8,x0,0x3FC → x8=0x3FC (base; uimm=4 → addr=0x400)
    //   ADDI x9,x0,0xBEEF... only 12-bit imm, use 0x7FF as test value
    //   C.SW x9',0(x8')  (uimm=4, rs1'=x8=3'b000, rs2'=x9=3'b001)
    //   C.LW x10',4(x8') (same uimm=4, rd'=x10=3'b010)
    //   SW x10,0x200(x0)
    //
    // uimm=4: enc_c_sw(rs2'=3'b001, rs1'=3'b000, uimm=7'd4)
    // x8 compact = 3'b000, x9 compact = 3'b001, x10 compact = 3'b010
    // ========================================================================
    $display("\n--- TEST 9: C.LW / C.SW round-trip ---");
    do_reset();
    pack_w(0, enc_i(12'h3FC, 5'd0, 3'b000, 5'd8, OP_IALU));   // ADDI x8,x0,0x3FC
    pack_w(1, enc_i(12'h7FF, 5'd0, 3'b000, 5'd9, OP_IALU));   // ADDI x9,x0,0x7FF
    // C.SW x9,4(x8): rs2'=x9=3'b001, rs1'=x8=3'b000, uimm=4
    // C.LW x10,4(x8): rd'=x10=3'b010, rs1'=x8=3'b000, uimm=4
    pack_hh(2, enc_c_sw(3'b001, 3'b000, 7'd4),
               enc_c_lw(3'b010, 3'b000, 7'd4));
    pack_w(3, enc_s(12'h200, 5'd10, 5'd0, 3'b010, OP_STOR));
    pack_w(4, NOP32); pack_w(5, NOP32); pack_w(6, NOP32);
    run_cycles(14);
    // Spec: store 0x7FF to dmem[0x400], load back to x10; x10=0x7FF
    check32("C.LW/C.SW round-trip: x10=0x7FF",
            dmem_word(10'h200), 32'h000007FF);

    // ========================================================================
    // TEST 10: C.ADDI, C.LI, C.LUI, C.MV, C.ADD
    //
    // 10a: C.ADDI rd,nzimm — spec §12.4: ADDI rd,rd,sext(nzimm)
    //   x15=10 (ADDI 32-bit), then C.ADDI x15,3 → x15=13
    //
    // 10b: C.LI rd,imm — spec §12.4: ADDI rd,x0,sext(imm)
    //   C.LI x13,-5 → x13=sext(-5)=0xFFFFFFFB
    //
    // 10c: C.LUI rd,nzimm — spec §12.4: LUI rd,sext(nzimm[17:12])
    //   C.LUI x14, nzimm[5:0]=0x01 → rd = 0x00001000
    //   (nzimm[17:12]=1 → upper immediate = 1 → rd = 1<<12 = 0x1000)
    //
    // 10d: C.MV rd,rs2 — spec §12.5: ADD rd,x0,rs2
    //   x3=21 (32-bit ADDI), C.MV x4,x3 → x4=21
    //
    // 10e: C.ADD rd,rs2 — spec §12.5: ADD rd,rd,rs2
    //   x3=10, x4=7, C.ADD x3,x4 → x3=17
    // ========================================================================
    $display("\n--- TEST 10a: C.ADDI ---");
    do_reset();
    pack_w(0, enc_i(12'd10, 5'd0, 3'b000, 5'd15, OP_IALU));   // ADDI x15,x0,10
    pack_h_lo(1, enc_c_addi(5'd15, 6'd3));   // C.ADDI x15,3
    pack_w(2, enc_s(12'h200, 5'd15, 5'd0, 3'b010, OP_STOR));
    pack_w(3, NOP32); pack_w(4, NOP32);
    run_cycles(10);
    // Spec §12.4: ADDI x15,x15,3 = 10+3=13
    check32("C.ADDI x15,3 (10+3) -> 13",
            dmem_word(10'h200), 32'h0000000D);

    $display("\n--- TEST 10b: C.LI negative ---");
    do_reset();
    pack_h_lo(0, enc_c_li(5'd13, 6'b111011));   // C.LI x13,-5 (6'b111011=-5)
    pack_w(1, enc_s(12'h200, 5'd13, 5'd0, 3'b010, OP_STOR));
    pack_w(2, NOP32); pack_w(3, NOP32);
    run_cycles(10);
    // Spec §12.4: ADDI x13,x0,sext(-5) = 0xFFFFFFFB
    check32("C.LI x13,-5 -> 0xFFFFFFFB",
            dmem_word(10'h200), 32'hFFFFFFFB);

    $display("\n--- TEST 10c: C.LUI ---");
    do_reset();
    // C.LUI x14, nzimm=1 → LUI x14, 1 → x14=0x00001000
    pack_h_lo(0, enc_c_lui(5'd14, 6'd1));
    pack_w(1, enc_s(12'h200, 5'd14, 5'd0, 3'b010, OP_STOR));
    pack_w(2, NOP32); pack_w(3, NOP32);
    run_cycles(10);
    // Spec §12.4: LUI x14,1 → x14 = 1<<12 = 0x1000
    check32("C.LUI x14,1 -> 0x00001000",
            dmem_word(10'h200), 32'h00001000);

    $display("\n--- TEST 10d: C.MV ---");
    do_reset();
    pack_w(0, enc_i(12'd21, 5'd0, 3'b000, 5'd3, OP_IALU));    // ADDI x3,x0,21
    pack_h_lo(1, enc_c_mv(5'd4, 5'd3));     // C.MV x4,x3
    pack_w(2, enc_s(12'h200, 5'd4, 5'd0, 3'b010, OP_STOR));
    pack_w(3, NOP32); pack_w(4, NOP32);
    run_cycles(10);
    // Spec §12.5: ADD x4,x0,x3 = x3 = 21
    check32("C.MV x4,x3 (x3=21) -> x4=21",
            dmem_word(10'h200), 32'h00000015);

    $display("\n--- TEST 10e: C.ADD ---");
    do_reset();
    pack_w(0, enc_i(12'd10, 5'd0, 3'b000, 5'd3, OP_IALU));    // ADDI x3,x0,10
    pack_w(1, enc_i(12'd7,  5'd0, 3'b000, 5'd4, OP_IALU));    // ADDI x4,x0,7
    pack_h_lo(2, enc_c_add(5'd3, 5'd4));    // C.ADD x3,x4 @ PC=8
    pack_w(3, enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR));   // SW x3,0x200(x0)
    pack_w(4, NOP32); pack_w(5, NOP32);
    run_cycles(12);
    // Spec §12.5: ADD x3,x3,x4 = 10+7=17
    check32("C.ADD x3,x4 (10+7) -> 17",
            dmem_word(10'h200), 32'h00000011);

    // ========================================================================
    // TEST 11: C.SUB, C.AND, C.OR, C.XOR
    // Spec §12.4: compact ALU ops on rd',rs2' (x8..x15).
    // x8=compact 3'b000, x9=3'b001, x10=3'b010, x11=3'b011.
    //
    // 11a: C.SUB x8,x9 (x8=15,x9=4) → x8 = SUB(15,4) = 11
    // 11b: C.AND x8,x9 (x8=0xFF,x9=0x0F) → x8 = 0xFF & 0x0F = 0x0F
    // 11c: C.OR  x8,x9 (x8=0xF0,x9=0x0F) → x8 = 0xF0|0x0F = 0xFF
    // 11d: C.XOR x8,x9 (x8=0xFF,x9=0x55) → x8 = 0xFF^0x55 = 0xAA
    // ========================================================================
    $display("\n--- TEST 11a: C.SUB ---");
    do_reset();
    pack_w(0, enc_i(12'd15, 5'd0, 3'b000, 5'd8, OP_IALU));
    pack_w(1, enc_i(12'd4,  5'd0, 3'b000, 5'd9, OP_IALU));
    pack_h_lo(2, enc_c_sub(3'b000, 3'b001));  // C.SUB x8,x9
    pack_w(3, enc_s(12'h200, 5'd8, 5'd0, 3'b010, OP_STOR));
    pack_w(4, NOP32); pack_w(5, NOP32);
    run_cycles(12);
    // Spec: SUB x8,x8,x9 = 15-4 = 11
    check32("C.SUB x8,x9 (15-4) -> 11",
            dmem_word(10'h200), 32'h0000000B);

    $display("\n--- TEST 11b: C.AND ---");
    do_reset();
    pack_w(0, enc_i(12'hFF,  5'd0, 3'b000, 5'd8, OP_IALU));
    pack_w(1, enc_i(12'h00F, 5'd0, 3'b000, 5'd9, OP_IALU));
    pack_h_lo(2, enc_c_and(3'b000, 3'b001));
    pack_w(3, enc_s(12'h200, 5'd8, 5'd0, 3'b010, OP_STOR));
    pack_w(4, NOP32); pack_w(5, NOP32);
    run_cycles(12);
    // Spec: AND x8,x8,x9 = 0xFF & 0x0F = 0x0F
    check32("C.AND x8,x9 (0xFF&0x0F) -> 0x0F",
            dmem_word(10'h200), 32'h0000000F);

    $display("\n--- TEST 11c: C.OR ---");
    do_reset();
    pack_w(0, enc_i(12'hF0,  5'd0, 3'b000, 5'd8, OP_IALU));
    pack_w(1, enc_i(12'h00F, 5'd0, 3'b000, 5'd9, OP_IALU));
    pack_h_lo(2, enc_c_or(3'b000, 3'b001));
    pack_w(3, enc_s(12'h200, 5'd8, 5'd0, 3'b010, OP_STOR));
    pack_w(4, NOP32); pack_w(5, NOP32);
    run_cycles(12);
    // Spec: OR x8,x8,x9 = 0xF0|0x0F = 0xFF
    check32("C.OR x8,x9 (0xF0|0x0F) -> 0xFF",
            dmem_word(10'h200), 32'h000000FF);

    $display("\n--- TEST 11d: C.XOR ---");
    do_reset();
    pack_w(0, enc_i(12'hFF,  5'd0, 3'b000, 5'd8, OP_IALU));
    pack_w(1, enc_i(12'h055, 5'd0, 3'b000, 5'd9, OP_IALU));
    pack_h_lo(2, enc_c_xor(3'b000, 3'b001));
    pack_w(3, enc_s(12'h200, 5'd8, 5'd0, 3'b010, OP_STOR));
    pack_w(4, NOP32); pack_w(5, NOP32);
    run_cycles(12);
    // Spec: XOR x8,x8,x9 = 0xFF^0x55 = 0xAA
    check32("C.XOR x8,x9 (0xFF^0x55) -> 0xAA",
            dmem_word(10'h200), 32'h000000AA);

    // ========================================================================
    // TEST 12: C.SLLI, C.SRLI, C.SRAI
    // Spec §12.4 (SRLI/SRAI/ANDI) and §12.5 (SLLI).
    //
    // 12a: C.SLLI x10,3 (x10=8) → x10 = 8<<3 = 64
    //   Spec §12.5: SLLI rd,rd,shamt
    //
    // 12b: C.SRLI x8,2  (x8=0x20=32) → x8 = 32>>2 = 8 (logical zero-fill)
    //   Spec §12.4 funct3=100,inst[11:10]=00
    //
    // 12c: C.SRAI x8,3  (x8=0xFFFFFF80=-128) → x8 = -128>>>3 = -16 = 0xFFFFFFF0
    //   Spec §12.4 funct3=100,inst[11:10]=01 (arithmetic)
    // ========================================================================
    $display("\n--- TEST 12a: C.SLLI ---");
    do_reset();
    pack_w(0, enc_i(12'd8, 5'd0, 3'b000, 5'd10, OP_IALU));    // ADDI x10,x0,8
    pack_h_lo(1, enc_c_slli(5'd10, 5'd3));  // C.SLLI x10,3
    pack_w(2, enc_s(12'h200, 5'd10, 5'd0, 3'b010, OP_STOR));
    pack_w(3, NOP32); pack_w(4, NOP32);
    run_cycles(10);
    // Spec: SLLI x10,x10,3 = 8<<3 = 64 = 0x40
    check32("C.SLLI x10,3 (8<<3) -> 64",
            dmem_word(10'h200), 32'h00000040);

    $display("\n--- TEST 12b: C.SRLI ---");
    do_reset();
    pack_w(0, enc_i(12'h020, 5'd0, 3'b000, 5'd8, OP_IALU));   // ADDI x8,x0,32
    pack_h_lo(1, enc_c_srli(3'b000, 5'd2));  // C.SRLI x8,2
    pack_w(2, enc_s(12'h200, 5'd8, 5'd0, 3'b010, OP_STOR));
    pack_w(3, NOP32); pack_w(4, NOP32);
    run_cycles(10);
    // Spec: SRLI x8,x8,2 = 32>>2 = 8
    check32("C.SRLI x8,2 (32>>2) -> 8",
            dmem_word(10'h200), 32'h00000008);

    $display("\n--- TEST 12c: C.SRAI ---");
    do_reset();
    // ADDI x8,x0,-128: imm=-128 = 12'hF80
    pack_w(0, enc_i(12'hF80, 5'd0, 3'b000, 5'd8, OP_IALU));
    pack_h_lo(1, enc_c_srai(3'b000, 5'd3));   // C.SRAI x8,3
    pack_w(2, enc_s(12'h200, 5'd8, 5'd0, 3'b010, OP_STOR));
    pack_w(3, NOP32); pack_w(4, NOP32);
    run_cycles(10);
    // Spec: SRAI x8,x8,3 = -128>>>3 = -16 = 0xFFFFFFF0
    check32("C.SRAI x8,3 (-128>>>3) -> 0xFFFFFFF0",
            dmem_word(10'h200), 32'hFFFFFFF0);

    // ========================================================================
    // TEST 13: C.ADDI4SPN AND C.ADDI16SP
    // Spec §12.3: C.ADDI4SPN rd',nzuimm = ADDI rd',x2,nzuimm
    //   nzuimm is zero-extended, scaled ×4.
    //
    // Spec §12.4: C.ADDI16SP nzimm = ADDI x2,x2,sext(nzimm)
    //   nzimm is sign-extended, scaled ×16.
    //
    // 13a: x2=0x100, C.ADDI4SPN x8,40  → x8 = x2+40 = 0x100+40 = 0x128
    //   (nzuimm=40, scaled by 4 in encoding: nzuimm field=40 directly since
    //   the spec says the immediate IS already the byte offset)
    //
    // 13b: x2=0x200, C.ADDI16SP +32 → x2 = 0x200+32 = 0x220
    //   (nzimm=32, multiple of 16)
    // ========================================================================
    $display("\n--- TEST 13a: C.ADDI4SPN ---");
    do_reset();
    pack_w(0, enc_i(12'h100, 5'd0, 3'b000, 5'd2, OP_IALU));   // ADDI x2,x0,0x100
    // C.ADDI4SPN rd'=x8=3'b000, nzuimm=40
    pack_h_lo(1, enc_c_addi4spn(3'b000, 10'd40));
    pack_w(2, enc_s(12'h200, 5'd8, 5'd0, 3'b010, OP_STOR));
    pack_w(3, NOP32); pack_w(4, NOP32);
    run_cycles(10);
    // Spec: ADDI x8,x2,40 = 0x100+40 = 0x100+0x28 = 0x128
    check32("C.ADDI4SPN x8,40 (x2=0x100) -> 0x128",
            dmem_word(10'h200), 32'h00000128);

    $display("\n--- TEST 13b: C.ADDI16SP ---");
    do_reset();
    pack_w(0, enc_i(12'h200, 5'd0, 3'b000, 5'd2, OP_IALU));   // ADDI x2,x0,0x200
    // C.ADDI16SP nzimm=32: nzimm[9:0]=10'b00_0010_0000 = 10'd32
    pack_h_lo(1, enc_c_addi16sp(10'd32));
    pack_w(2, enc_s(12'h200, 5'd2, 5'd0, 3'b010, OP_STOR));
    pack_w(3, NOP32); pack_w(4, NOP32);
    run_cycles(10);
    // Spec: ADDI x2,x2,32 = 0x200+32 = 0x220
    check32("C.ADDI16SP +32 (x2=0x200) -> x2=0x220",
            dmem_word(10'h200), 32'h00000220);

    // ========================================================================
    // TEST 14: C.JR AND C.JALR
    // Spec §12.5:
    //   C.JR rs1  = JALR x0, 0(rs1) — jump to rs1, no link
    //   C.JALR rs1 = JALR x1, 0(rs1) — jump to rs1, x1 = PC+2
    //
    // 14a: C.JR x5 — x5=0x20=32, jump to PC=32
    //   At PC=32: C.LI x6,55 then SW x6.
    //   Verify x6=55 (jumped correctly).
    //
    // 14b: C.JALR x5 — x5=0x20=32, jump to PC=32, x1=PC+2.
    //   C.JALR is at PC=4 → x1 = 4+2 = 6.
    //   Verify x1=6 and x6=55.
    // ========================================================================
    $display("\n--- TEST 14a: C.JR ---");
    do_reset();
    pack_w(0, enc_i(12'h020, 5'd0, 3'b000, 5'd5, OP_IALU));   // ADDI x5,x0,0x20
    pack_h_lo(1, enc_c_jr(5'd5));   // C.JR x5 @ PC=4
    // PC=6: flushed bubble
    // PC=8..PC=30: NOPs (imem default)
    // PC=32 = imem[8][15:0]: C.LI x6,19
    pack_h_lo(8, enc_c_li(5'd6, 6'd19));
    pack_w(9, enc_s(12'h200, 5'd6, 5'd0, 3'b010, OP_STOR));
    pack_w(10, NOP32); pack_w(11, NOP32);
    run_cycles(16);
    // Spec: C.JR jumps to x5=0x20=32; x6=19
    check32("C.JR x5 (x5=32): x6=19",
            dmem_word(10'h200), 32'h00000013);

    $display("\n--- TEST 14b: C.JALR link = PC+2 ---");
    do_reset();
    pack_w(0, enc_i(12'h020, 5'd0, 3'b000, 5'd5, OP_IALU));   // ADDI x5,x0,0x20
    pack_h_lo(1, enc_c_jalr(5'd5));  // C.JALR x5 @ PC=4 → x1=6
    // PC=32 = imem[8][15:0]: C.LI x6,19
    pack_h_lo(8, enc_c_li(5'd6, 6'd19));
    pack_w(9, enc_s(12'h200, 5'd1, 5'd0, 3'b010, OP_STOR));   // SW x1,0x200
    pack_w(10, enc_s(12'h204, 5'd6, 5'd0, 3'b010, OP_STOR));  // SW x6,0x204
    pack_w(11, NOP32); pack_w(12, NOP32);
    run_cycles(18);
    // Spec: C.JALR at PC=4 → x1=PC+2=6; target x6=19
    check32("C.JALR link x1=6",  dmem_word(10'h200), 32'h00000006);
    check32("C.JALR target x6=19", dmem_word(10'h204), 32'h00000013);

    // ========================================================================
    // TEST 15: C.EBREAK
    // Spec §12.5: C.EBREAK = EBREAK = {12'b1, 5'b0, 3'b000, 5'b0, 7'b1110011}
    // = 32'h00100073 expanded. C.EBREAK = 16'h9002.
    // Spec §1.8: EBREAK asserts halt_o.
    // halt_o is TRANSIENT — asserted only while instruction is in EX.
    // C.EBREAK at PC=0: fetched cycle 0, in EX cycle 1 → halt_o=1 at cycle 1.
    // ========================================================================
    $display("\n--- TEST 15: C.EBREAK ---");
    do_reset();
    pack_h_lo(0, C_EBREAK);   // C.EBREAK @ PC=0
    run_cycles(1);
    // Spec §1.8 + §12.5: C.EBREAK → EBREAK → halt_o=1
    check1("C.EBREAK: halt_o=1", halt_o, 1'b1);
    run_cycles(1);
    check1("C.EBREAK: halt_o clears next cycle", halt_o, 1'b0);

    // ========================================================================
    // TEST 16: ILLEGAL COMPRESSED INSTRUCTION
    // Spec §12.7: C0 funct3 ∈ {001,011,100,101,111} are illegal.
    // Use C0 funct3=001 (F-extension C.FLD, not present in RV32 without F).
    // Encoding: {3'b001, ...various..., 2'b00} — any C0 funct3=001 encoding.
    // The compressed_decoder outputs 32'h00000000 (all-zero) for illegal
    // encodings (spec §12.1: 16'h0000 is always illegal → control_decoder
    // flags illegal → halt_o=1).
    //
    // Illegal C0 word: {3'b001, 8'b0, 2'b00} with bits[1:0]=00.
    // = 16'b001_00000_00000_00 = 16'h2000? Let's construct explicitly:
    // [15:13]=001, [12:2]=arbitrary, [1:0]=00
    // Use 16'h2000 = {3'b001, 10'b0, 2'b00}. bits[1:0]=00 → C0 quadrant.
    // ========================================================================
    $display("\n--- TEST 16: Illegal compressed instruction ---");
    do_reset();
    pack_h_lo(0, 16'h2000);  // C0 funct3=001 — illegal (§12.7 rule 2)
    run_cycles(1);
    // Spec §12.7: illegal → compressed_decoder outputs 32'h0 → halt_o=1
    check1("Illegal C0 funct3=001: halt_o=1", halt_o, 1'b1);

    // ========================================================================
    // TEST 17: FORWARDING — COMPRESSED RESULT FORWARDED
    // Spec §7.3: WB-to-EX forwarding. Back-to-back compressed instructions.
    //   C.LI x10,7  (fetched cycle 0, WB at cycle 2 → x10=7)
    //   C.ADDI x10,3 (fetched cycle 1, EX at cycle 2 — x10 forwarded from WB)
    //   → x10 = 7+3 = 10
    //
    // Without forwarding: C.ADDI would see stale x10=0 → x10=3. WRONG.
    //
    // Packing:
    //   imem[0][15:0] = C.LI x10,7 (PC=0)
    //   imem[0][31:16]= C.ADDI x10,3 (PC=2)
    //   imem[1] = SW x10,0x200(x0)
    // ========================================================================
    $display("\n--- TEST 17: Forwarding with compressed instructions ---");
    do_reset();
    pack_hh(0, enc_c_li(5'd10, 6'd7),
               enc_c_addi(5'd10, 6'd3));
    pack_w(1, enc_s(12'h200, 5'd10, 5'd0, 3'b010, OP_STOR));
    pack_w(2, NOP32); pack_w(3, NOP32);
    run_cycles(8);
    // Spec: x10=7 from C.LI, forwarded to C.ADDI → x10=7+3=10
    check32("Compressed forwarding: C.LI x10,7 + C.ADDI x10,3 -> 10",
            dmem_word(10'h200), 32'h0000000A);

    // ========================================================================
    // TEST 18: FLUSH CORRECTNESS AFTER BRANCH
    // Spec §12.6: Flush clears upper_valid.
    // After a taken C.BEQZ, the alignment buffer must be empty at the target.
    // Verify by placing a 32-bit instruction at the branch target (word-aligned)
    // and confirming it executes correctly — if upper_valid were erroneously
    // set, the pipeline would decode a corrupted instruction.
    //
    // Program:
    //   PC=0: C.LI x8,0
    //   PC=2: C.BEQZ x8,+6 → taken, PC→8
    //   PC=4: C.LI x9,77   (flushed bubble)
    //   PC=8: ADDI x9,x0,42 (32-bit at word-aligned target, PC=8=imem[2])
    //   SW x9,0x200(x0)
    //
    // If upper_valid is incorrectly set after flush, imem[2] would be decoded
    // with a stale upper_buf, producing a different (wrong) instruction.
    // Expected: x9=42.
    // ========================================================================
    $display("\n--- TEST 18: Flush clears alignment buffer ---");
    do_reset();
    pack_hh(0, enc_c_li(5'd8, 6'd0),
               enc_c_beqz(3'b000, 9'd6));
    pack_h_lo(1, enc_c_li(5'd9, 6'd29)); // PC=4, flushed
    pack_w(2, enc_i(12'd42, 5'd0, 3'b000, 5'd9, OP_IALU));    // ADDI x9,x0,42
    pack_w(3, enc_s(12'h200, 5'd9, 5'd0, 3'b010, OP_STOR));
    pack_w(4, NOP32); pack_w(5, NOP32);
    run_cycles(12);
    // Spec: branch flushes upper_valid; 32-bit ADDI executes cleanly → x9=42
    check32("Flush clears alignment buf: 32-bit at target x9=42",
            dmem_word(10'h200), 32'h0000002A);

    // ========================================================================
    // TEST 19: x0 SUPPRESSION WITH COMPRESSED
    // Spec §12.4: C.LI with rd=x0 is a HINT (treated as NOP). x0 must remain 0.
    // Verify that writing to x0 via compressed instruction has no effect.
    //
    // Program:
    //   C.LI x0,5   (HINT — x0 stays 0)
    //   SW x0,0x200(x0)
    //   Verify dmem[0x200]=0
    // ========================================================================
    $display("\n--- TEST 19: x0 suppression with compressed C.LI ---");
    do_reset();
    pack_h_lo(0, enc_c_li(5'd0, 6'd5));    // C.LI x0,5 (HINT)
    pack_w(1, enc_s(12'h200, 5'd0, 5'd0, 3'b010, OP_STOR));
    pack_w(2, NOP32); pack_w(3, NOP32);
    run_cycles(8);
    // Spec §9.2: x0 hardwired to 0. C.LI x0,5 is HINT (no effect) → x0=0.
    check32("C.LI x0,5 (HINT): x0 stays 0",
            dmem_word(10'h200), 32'h00000000);

    // ========================================================================
    // TEST 20: M1 REGRESSION — ALL 32-BIT PROGRAM
    // Verify that the alignment buffer stays quiet (upper_valid=0 throughout)
    // when running a program consisting entirely of 32-bit instructions.
    // All instructions at word-aligned PCs; no compressed instructions.
    //
    // Program (spec §1.2, §1.1):
    //   ADDI x1,x0,10  → x1=10
    //   ADDI x2,x0,20  → x2=20
    //   ADD  x3,x1,x2  → x3=30
    //   SW   x3,0x200(x0)
    // Expected: x3=30
    // ========================================================================
    $display("\n--- TEST 20: M1 regression (all 32-bit, no compressed) ---");
    do_reset();
    pack_w(0, enc_i(12'd10, 5'd0, 3'b000, 5'd1, OP_IALU));    // ADDI x1,x0,10
    pack_w(1, enc_i(12'd20, 5'd0, 3'b000, 5'd2, OP_IALU));    // ADDI x2,x0,20
    pack_w(2, NOP32);
    pack_w(3, enc_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, OP_R)); // ADD x3,x1,x2
    pack_w(4, NOP32); pack_w(5, NOP32);
    pack_w(6, enc_s(12'h200, 5'd3, 5'd0, 3'b010, OP_STOR));
    pack_w(7, NOP32); pack_w(8, NOP32);
    pack_w(9, NOP32); pack_w(10, NOP32);
    run_cycles(13);
    // Spec §1.1: ADD x3,x1,x2 = 10+20 = 30
    check32("M1 regression: ADDI+ADDI+ADD x3=30",
            dmem_word(10'h200), 32'h0000001E);
    // Also verify halt_o is not spuriously asserted
    check1("M1 regression: halt_o=0", halt_o, 1'b0);

    // ========================================================================
    // SUMMARY
    // ========================================================================
    $display("\n========================================");
    $display("tb_pipeline_compressed COMPLETE");
    $display("  PASS: %0d", pass_count);
    $display("  FAIL: %0d", fail_count);
    $display("========================================");
    if (fail_count == 0)
      $display("ALL TESTS PASSED");
    else begin
      $display("SOME TESTS FAILED — review RTL vs canonical-reference.md §12");
      $fatal(1, "tb_pipeline_compressed: %0d test(s) failed", fail_count);
    end
    $finish;
  end

  // ==========================================================================
  // Timeout watchdog
  // ==========================================================================
  initial begin
    #600000; // 600 us limit
    $display("TIMEOUT: simulation exceeded 600us. TB or DUT hung.");
    $finish;
  end

endmodule
