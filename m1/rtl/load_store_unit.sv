// ============================================================================
// Module: load_store_unit
// Description: Combinational LSU. Generates byte-lane-aligned store data and
//              write-enables for stores; performs sign/zero extension for
//              loads. Purely combinational — no clock or reset ports.
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================

module load_store_unit (
  // ---- Store path inputs -----------------------------------------------
  input  logic [31:0] rs2_i,       // Store source data
  input  logic [31:0] addr_i,      // Effective byte address (ALU result)
  input  logic [2:0]  funct3_i,    // Instruction funct3
  input  logic        mem_write_i, // 1 = store instruction
  input  logic        mem_read_i,  // 1 = load instruction

  // ---- Memory interface (store) ----------------------------------------
  output logic [31:0] store_data_o, // Byte-lane-aligned write data
  output logic [3:0]  data_we_o,    // Active-high byte write enables

  // ---- Memory interface (load) -----------------------------------------
  input  logic [31:0] load_raw_i,  // Raw 32-bit word from data memory
  output logic [31:0] load_data_o  // Sign/zero-extended load result
);

  // =========================================================================
  // Localparams — funct3 encodings (canonical-reference.md S1.3, S1.4)
  // =========================================================================

  // Load funct3
  localparam FUNCT3_LB  = 3'b000;
  localparam FUNCT3_LH  = 3'b001;
  localparam FUNCT3_LW  = 3'b010;
  localparam FUNCT3_LBU = 3'b100;
  localparam FUNCT3_LHU = 3'b101;

  // Store funct3
  localparam FUNCT3_SB  = 3'b000;
  localparam FUNCT3_SH  = 3'b001;
  localparam FUNCT3_SW  = 3'b010;

  // =========================================================================
  // Internal signals
  // =========================================================================

  // Byte offset within the aligned word
  logic [1:0] byte_off;
  assign byte_off = addr_i[1:0];

  // Extracted byte/halfword from raw load data, before extension
  logic [7:0]  load_byte;
  logic [15:0] load_half;

  // =========================================================================
  // Store path — byte-lane alignment
  //
  // Data is replicated to all relevant byte lanes; data_we selects which
  // lanes the memory actually writes.  The memory ignores inactive lanes.
  //
  // SB: replicate byte to all 4 lanes; data_we = 4'b0001 << byte_off
  // SH: replicate halfword to both halfwords; data_we depends on addr[1]
  // SW: pass full word; data_we = 4'b1111
  // =========================================================================

  always_comb begin
    // Defaults — prevent latch inference (gotcha #1)
    store_data_o = 32'h0;
    data_we_o    = 4'b0000;

    if (mem_write_i) begin
      case (funct3_i)
        FUNCT3_SB: begin
          // Replicate byte to all 4 lanes; memory selects via data_we
          store_data_o = {4{rs2_i[7:0]}};
          data_we_o    = 4'b0001 << byte_off;
        end

        FUNCT3_SH: begin
          // Replicate halfword to both halfwords; memory selects via data_we
          store_data_o = {2{rs2_i[15:0]}};
          data_we_o    = byte_off[1] ? 4'b1100 : 4'b0011;
        end

        FUNCT3_SW: begin
          store_data_o = rs2_i;
          data_we_o    = 4'b1111;
        end

        default: begin
          store_data_o = 32'h0;
          data_we_o    = 4'b0000;
        end
      endcase
    end
  end

  // =========================================================================
  // Load path — byte/halfword extraction
  //
  // byte_off selects which of the four bytes (or two halfwords) to extract
  // from the aligned 32-bit word returned by memory.  Misaligned access is
  // undefined behavior per the canonical reference — no trap logic required.
  // =========================================================================

  // -- Byte extraction: pick byte lane from raw load word ------------------
  always_comb begin
    // Default (gotcha #1)
    load_byte = 8'h0;
    case (byte_off)
      2'b00: load_byte = load_raw_i[7:0];
      2'b01: load_byte = load_raw_i[15:8];
      2'b10: load_byte = load_raw_i[23:16];
      2'b11: load_byte = load_raw_i[31:24];
      default: load_byte = 8'h0;
    endcase
  end

  // -- Halfword extraction: pick lower or upper halfword -------------------
  always_comb begin
    // Default (gotcha #1)
    load_half = 16'h0;
    case (byte_off[1])
      1'b0: load_half = load_raw_i[15:0];
      1'b1: load_half = load_raw_i[31:16];
      default: load_half = 16'h0;
    endcase
  end

  // -- Final load data mux: extension + instruction routing ----------------
  always_comb begin
    // Default (gotcha #1)
    load_data_o = 32'h0;

    if (mem_read_i) begin
      case (funct3_i)
        FUNCT3_LB:  load_data_o = {{24{load_byte[7]}}, load_byte};
        FUNCT3_LBU: load_data_o = {24'h0,              load_byte};
        FUNCT3_LH:  load_data_o = {{16{load_half[15]}}, load_half};
        FUNCT3_LHU: load_data_o = {16'h0,               load_half};
        FUNCT3_LW:  load_data_o = load_raw_i;
        default:    load_data_o = 32'h0;
      endcase
    end
  end

endmodule
