// ============================================================================
// Module: regfile
// Description: RV32I register file — 32×32 flip-flop based, no SRAM.
//              2 async read ports, 1 sync write port. x0 hardwired to zero.
// Author: Beaux Cable
// Date: April 2026
// Project: RV32I Pipelined Processor
// ============================================================================

module regfile (
    input  logic        clk,
    input  logic        rst_n,          // active-low reset

    // Write port
    input  logic        wr_en_i,        // write enable
    input  logic [4:0]  wr_addr_i,      // destination register (rd)
    input  logic [31:0] wr_data_i,      // data to write

    // Read port A
    input  logic [4:0]  rd_addr_a_i,    // source register 1 (rs1)
    output logic [31:0] rd_data_a_o,    // read data 1

    // Read port B
    input  logic [4:0]  rd_addr_b_i,    // source register 2 (rs2)
    output logic [31:0] rd_data_b_o     // read data 2
);

    // 32 registers, each 32 bits wide
    logic [31:0] regs [31:0];

    // ----------------------------------------------------------
    // Read logic — asynchronous (combinational)
    // x0 always reads as zero regardless of what's stored
    // ----------------------------------------------------------
    assign rd_data_a_o = (rd_addr_a_i == 5'b0) ? 32'h0 : regs[rd_addr_a_i];
    assign rd_data_b_o = (rd_addr_b_i == 5'b0) ? 32'h0 : regs[rd_addr_b_i];

    // ----------------------------------------------------------
    // Write logic — synchronous, x0 is never written
    // Read-during-write returns OLD value; pipeline handles forwarding.
    // ----------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) begin
                regs[i] <= 32'h0;
            end
        end else if (wr_en_i && wr_addr_i != 5'b0) begin
            regs[wr_addr_i] <= wr_data_i;
        end
    end

endmodule
