// ============================================================
// RV32I Register File — Flip-Flop Based
// ============================================================
// 32 registers × 32 bits, implemented entirely in flip-flops
// (no SRAM, no memory compiler needed).
//
// - 2 asynchronous read ports (combinational)
// - 1 synchronous write port (posedge clk)
// - x0 is hardwired to zero per RISC-V spec
//
// Read-during-write behavior: if you read and write the same
// register in the same cycle, the read returns the OLD value.
// The forwarding logic in the pipeline will handle this.
// ============================================================

module regfile (
    input  logic        clk,
    input  logic        rst_n,       // active-low reset

    // Write port
    input  logic        wr_en,       // write enable
    input  logic [4:0]  wr_addr,     // destination register (rd)
    input  logic [31:0] wr_data,     // data to write

    // Read port A
    input  logic [4:0]  rd_addr_a,   // source register 1 (rs1)
    output logic [31:0] rd_data_a,   // read data 1

    // Read port B
    input  logic [4:0]  rd_addr_b,   // source register 2 (rs2)
    output logic [31:0] rd_data_b    // read data 2
);

    // 32 registers, each 32 bits wide
    logic [31:0] regs [31:0];

    // ----------------------------------------------------------
    // Write logic — synchronous, x0 is never written
    // ----------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) begin
                regs[i] <= 32'b0;
            end
        end else if (wr_en && wr_addr != 5'b0) begin
            regs[wr_addr] <= wr_data;
        end
    end

    // ----------------------------------------------------------
    // Read logic — asynchronous (combinational)
    // x0 always reads as zero regardless of what's stored
    // ----------------------------------------------------------
    assign rd_data_a = (rd_addr_a == 5'b0) ? 32'b0 : regs[rd_addr_a];
    assign rd_data_b = (rd_addr_b == 5'b0) ? 32'b0 : regs[rd_addr_b];

endmodule
