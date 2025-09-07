module i2c_master_top(
input clk,
input nRst, // Active-low asynchronous reset

//Configuration Registers for the core.
input  [7:0] iCommand,
input  [31:0] iQuarterBitCounter,
input  [11:0] iBytesToWrite,
input  [11:0] iBytesToRead,

// Slave Address
input   [6:0] iSlaveAddr,

// TX/RX Buffer Interface (from external/testbench)
input         iTxBufWrEn,
input   [7:0] iTxBufDataIn,
input         iRxBufRdEn,
output  [7:0] oRxBufDataOut,

//Sync registers
output  [7:0] oStatusReg,
input  iStartSequence,
output  wire oSequenceDone,
output wire oDataRxDv,

//Physical level wires
input wire i_scl,
output wire o_scl,
output wire oe_scl,

input wire i_sda,
output wire o_sda,
output wire oe_sda
);

    // register file for TX and RX data
    reg [7:0] tx_buffer [0:2049];
    reg [7:0] rx_buffer [0:2047];

    // Internal pointers for FIFO-like buffer access
    reg [11:0] tx_wr_ptr;
    reg [10:0] rx_rd_ptr;

    // Wires to connect top-level to the core
    wire [11:0] core_data_byte_addr;
    wire [7:0] core_tx_data_in;
    wire       core_rx_data_wr_en;
    wire [7:0] core_rx_data_out;

    // Handle external writes to the TX buffer with auto-incrementing pointer
    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            tx_wr_ptr <= 12'b0;
        end else if (iStartSequence) begin // Reset pointer on new transaction
            tx_wr_ptr <= 12'b0;
        end else if (iTxBufWrEn) begin
            tx_buffer[tx_wr_ptr] <= iTxBufDataIn;
            tx_wr_ptr <= tx_wr_ptr + 1;
        end
    end

    // Handle external reads from the RX buffer with auto-incrementing pointer
    // This is a combinatorial read for simplicity, but the pointer update is synchronous.
    assign oRxBufDataOut = rx_buffer[rx_rd_ptr];
    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            rx_rd_ptr <= 11'b0;
        end else if (iStartSequence) begin // Reset pointer on new transaction
            rx_rd_ptr <= 11'b0;
        end else if (iRxBufRdEn) begin
            rx_rd_ptr <= rx_rd_ptr + 1;
        end
    end

    // --- Glue logic between top and core ---

    // Provide the core with the requested data byte from the TX buffer
    assign core_tx_data_in = tx_buffer[core_data_byte_addr];

    // When the core signals it has received a byte, write it to the RX buffer
    always @(posedge clk) begin
        if (core_rx_data_wr_en) begin
            rx_buffer[core_data_byte_addr] <= core_rx_data_out;
        end
    end

    i2c_core i2c_core_inst (
        .clk(clk),
        .nRst(nRst),
        .iCommand(iCommand),
        .iQuarterBitCounter(iQuarterBitCounter),
        .iBytesToWrite(iBytesToWrite),
        .iBytesToRead(iBytesToRead),
        .iSlaveAddr(iSlaveAddr),
        .oStatusReg(oStatusReg),
        .iStartSequence(iStartSequence),
        .oSequenceDone(oSequenceDone),
        .oDataRxDv(oDataRxDv),
        .oDataByteAddr(core_data_byte_addr),
        .iTxData(core_tx_data_in),
        .oRxDataWrEn(core_rx_data_wr_en),
        .oRxDataOut(core_rx_data_out),
        .i_scl(i_scl), .o_scl(o_scl), .oe_scl(oe_scl),
        .i_sda(i_sda), .o_sda(o_sda), .oe_sda(oe_sda)
    );

endmodule