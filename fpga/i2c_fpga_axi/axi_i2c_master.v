`timescale 1ns / 1ps

module axi_i2c_master #(
    // AXI Parameters
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 8
)
(
    // AXI4-Lite Slave Interface
    input  wire                               S_AXI_ACLK,
    input  wire                               S_AXI_ARESETN,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]      S_AXI_AWADDR,
    input  wire [2:0]                         S_AXI_AWPROT,
    input  wire                               S_AXI_AWVALID,
    output wire                               S_AXI_AWREADY,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]      S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]  S_AXI_WSTRB,
    input  wire                               S_AXI_WVALID,
    output wire                               S_AXI_WREADY,
    output wire [1:0]                         S_AXI_BRESP,
    output wire                               S_AXI_BVALID,
    input  wire                               S_AXI_BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]      S_AXI_ARADDR,
    input  wire [2:0]                         S_AXI_ARPROT,
    input  wire                               S_AXI_ARVALID,
    output wire                               S_AXI_ARREADY,
    output wire [C_S_AXI_DATA_WIDTH-1:0]      S_AXI_RDATA,
    output wire [1:0]                         S_AXI_RRESP,
    output wire                               S_AXI_RVALID,
    input  wire                               S_AXI_RREADY,

    // Interrupt
    output wire                               interrupt,

    // I2C Physical Interface
    input  wire                               i_scl,
    output wire                               o_scl,
    output wire                               oe_scl,
    input  wire                               i_sda,
    output wire                               o_sda,
    output wire                               oe_sda
);

    // AXI4-Lite signal declarations
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
    reg                          axi_awready;
    reg                          axi_wready;
    reg [1:0]                    axi_bresp;
    reg                          axi_bvalid;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;
    reg                          axi_arready;
    reg [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;
    reg [1:0]                    axi_rresp;
    reg                          axi_rvalid;

    // Address map localparams
    localparam integer ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;
    localparam integer OPT_MEM_ADDR_BITS = 5;

    // Register Address Map
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_CTRL_REG         = 8'h00;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_STATUS_REG       = 8'h04;
    localparam CTRL_SW_RESET_BIT       = 2;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_SLAVE_ADDR_REG   = 8'h08;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_BYTES_WRITE_REG  = 8'h0C;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_BYTES_READ_REG   = 8'h10;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_PRESCALER_REG    = 8'h14;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_IER_REG          = 8'h18; // Interrupt Enable Register
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_ISR_REG          = 8'h1C; // Interrupt Status Register
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_DUMMY_REG        = 8'h20; // Dummy R/W register for debug
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_VERSION_REG      = 8'h24; // Version Register
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_TX_DATA_REG      = 8'h40;
    localparam [C_S_AXI_ADDR_WIDTH-1:0] ADDR_RX_DATA_REG      = 8'h80;

    // Internal signals for connecting to the i2c_core
    reg  [7:0]  core_iCommand;
    reg  [31:0] core_iQuarterBitCounter;
    reg  [11:0] core_iBytesToWrite;
    reg  [11:0] core_iBytesToRead;
    reg  [6:0]  core_iSlaveAddr;
    reg         core_iStartSequence;
    wire [7:0]  core_oStatusReg;
    wire        core_oSequenceDone;
    wire        core_oDataRxDv;

    // TX/RX Buffer implementation (2048-byte RAM)
    reg [7:0] tx_buffer [0:2049];
    reg [7:0] rx_buffer [0:2047];
    wire [10:0] core_oDataByteAddr;
    wire [7:0] core_iTxData;
    wire       core_oRxDataWrEn;
    wire [7:0] core_oRxDataOut;
    reg  [10:0] tx_write_ptr; // Points to next empty spot in TX buffer
    reg  [10:0] rx_read_ptr;  // Points to next unread spot in RX buffer

    // Interrupt logic registers
    reg [1:0] ier; // Interrupt Enable Register
    reg [1:0] isr; // Interrupt Status Register

    // Debug and Versioning Registers
    reg [31:0] dummy_reg;
    localparam [31:0] VERSION = 32'h0001_0200; // Version 1.2.0.0

    // Wires for interrupt events
    wire ack_error_event;
    wire done_event;

    // Software Reset Logic
    reg  sw_reset;
    wire core_nRst;
    // Instantiate the I2C core
    i2c_core i2c_core_inst (
        .clk(S_AXI_ACLK),
        .nRst(core_nRst),
        .iCommand(core_iCommand),
        .iQuarterBitCounter(core_iQuarterBitCounter),
        .iBytesToWrite(core_iBytesToWrite),
        .iBytesToRead(core_iBytesToRead),
        .iSlaveAddr(core_iSlaveAddr),
        .iTxData(core_iTxData),
        .oDataByteAddr(core_oDataByteAddr),
        .oRxDataWrEn(core_oRxDataWrEn),
        .oRxDataOut(core_oRxDataOut),
        .oStatusReg(core_oStatusReg),
        .iStartSequence(core_iStartSequence),
        .oSequenceDone(core_oSequenceDone),
        .oDataRxDv(core_oDataRxDv),
        .i_scl(i_scl),
        .o_scl(o_scl),
        .oe_scl(oe_scl),
        .i_sda(i_sda),
        .o_sda(o_sda),
        .oe_sda(oe_sda)
    );

    // AXI Write Logic
    // We can accept a write address if the write channel is not already busy.
    assign S_AXI_AWREADY = ~axi_awready;
    // We can accept write data if an address has been latched and we are not already busy.
    assign S_AXI_WREADY = axi_awready && ~axi_wready;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_awaddr <= 0;
        end else begin
            // AXI handshake state machine
            if (S_AXI_AWREADY && S_AXI_AWVALID) begin
                axi_awready <= 1'b1;
                axi_awaddr <= S_AXI_AWADDR;
            end
            if (S_AXI_WREADY && S_AXI_WVALID) begin
                axi_wready <= 1'b1;
            end
            if (S_AXI_BREADY && axi_bvalid) begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b0;
            end
        end
    end

    // Memory-mapped register write logic
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            core_iCommand           <= 0;
            core_iQuarterBitCounter <= 0;
            core_iBytesToWrite      <= 0;
            core_iBytesToRead       <= 0;
            core_iSlaveAddr         <= 0;
            core_iStartSequence     <= 1'b0;
            ier                     <= 0;
            dummy_reg               <= 0;
            sw_reset                <= 1'b0;
        end else begin
            // Default: start pulse is self-clearing
            core_iStartSequence <= 1'b0;

            if (S_AXI_WREADY && S_AXI_WVALID && axi_awready) begin
                case (axi_awaddr)
                    ADDR_CTRL_REG: begin
                        core_iCommand       <= S_AXI_WDATA[1:0];
                        sw_reset            <= S_AXI_WDATA[CTRL_SW_RESET_BIT];
                        core_iStartSequence <= S_AXI_WDATA[8]; // Bit 8 is the start trigger
                        if (S_AXI_WDATA[8]) begin
                        end
                    end
                    ADDR_SLAVE_ADDR_REG:
                        core_iSlaveAddr <= S_AXI_WDATA[6:0];
                    ADDR_BYTES_WRITE_REG:
                        core_iBytesToWrite <= S_AXI_WDATA[11:0];
                    ADDR_BYTES_READ_REG:
                        core_iBytesToRead <= S_AXI_WDATA[11:0];
                    ADDR_PRESCALER_REG:
                        core_iQuarterBitCounter <= S_AXI_WDATA;
                    ADDR_TX_DATA_REG:
                        tx_buffer[tx_write_ptr] <= S_AXI_WDATA[7:0];
                    ADDR_IER_REG:
                        ier <= S_AXI_WDATA[1:0];
                    ADDR_ISR_REG:
                    ; 
                    ADDR_DUMMY_REG:
                        dummy_reg <= S_AXI_WDATA;
                    default: begin
                        // Do nothing for writes to other addresses
                    end
                endcase
            end
            // Ensure sw_reset is a single-cycle pulse
            else begin
                sw_reset <= 1'b0;
            end
        end
    end

    // AXI Write Response
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b0;
        end else begin
            if (axi_wready && axi_awready && ~axi_bvalid) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b0; // OKAY
            end else if (S_AXI_BREADY && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // AXI Read Logic - Refactored for robustness
    assign S_AXI_ARREADY = ~axi_arready;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0;
            axi_araddr  <= 0;
            axi_rvalid  <= 1'b0;
            axi_rresp   <= 2'b0; // Initialize RRESP on reset
        end else begin
            // When master requests a read and we are ready, latch the address
            // and prepare to send data on the next cycle.
            if (S_AXI_ARREADY && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                axi_araddr  <= S_AXI_ARADDR;
                axi_rresp   <= 2'b0; // Drive RRESP to OKAY for the transaction
                axi_rvalid  <= 1'b1; // Prepare to assert RVALID in the next cycle
            end
            // When the master takes the data, de-assert RVALID and get ready for a new read.
            else if (S_AXI_RREADY && axi_rvalid) begin
                axi_arready <= 1'b0;
                axi_rvalid  <= 1'b0;
            end
        end
    end

    // Memory-mapped register read logic - Pipelined for correct timing
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_rdata <= 0;
        end else begin
            // In the cycle where we accept the address, we select the data
            // which will be presented on the bus in the next cycle.
            if (S_AXI_ARREADY && S_AXI_ARVALID) begin
                case (S_AXI_ARADDR)
                    ADDR_CTRL_REG:        axi_rdata <= {23'b0, core_iStartSequence, 7'b0, core_iCommand};
                    ADDR_STATUS_REG:      axi_rdata <= {29'b0, core_oStatusReg[1], core_oSequenceDone, core_oStatusReg[0]}; // Bit 2: Idle, Bit 1: Done, Bit 0: ACK Error
                    ADDR_SLAVE_ADDR_REG:  axi_rdata <= {25'b0, core_iSlaveAddr};
                    ADDR_BYTES_WRITE_REG: axi_rdata <= {20'b0, core_iBytesToWrite};
                    ADDR_BYTES_READ_REG:  axi_rdata <= {20'b0, core_iBytesToRead};
                    ADDR_PRESCALER_REG:   axi_rdata <= core_iQuarterBitCounter;
                    ADDR_RX_DATA_REG:     axi_rdata <= {24'b0, rx_buffer[rx_read_ptr]};
                    ADDR_IER_REG:         axi_rdata <= {30'b0, ier};
                    ADDR_ISR_REG:         axi_rdata <= {30'b0, isr};
                    ADDR_DUMMY_REG:       axi_rdata <= dummy_reg;
                    ADDR_VERSION_REG:     axi_rdata <= VERSION;
                    default:              axi_rdata <= 0;
                endcase
            end
        end
    end


    // TX/RX Buffer Logic
    // Provide data from the TX buffer to the core
    assign core_iTxData = tx_buffer[core_oDataByteAddr];

    // TX Write Pointer Logic - Consolidated to a single driver
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            tx_write_ptr <= 0;
        end
        // Reset pointer when a new I2C transaction starts
        else if (S_AXI_WREADY && S_AXI_WVALID && axi_awready && axi_awaddr == ADDR_CTRL_REG && S_AXI_WDATA[8]) begin
            tx_write_ptr <= 0;
        end
        // Increment pointer when master writes to the TX FIFO
        else if (S_AXI_WREADY && S_AXI_WVALID && axi_awready && axi_awaddr == ADDR_TX_DATA_REG) begin
            if (tx_write_ptr < 2048) begin
                tx_write_ptr <= tx_write_ptr + 1;
            end
        end
    end

    // RX Read Pointer Logic - Consolidated to a single driver
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            rx_read_ptr <= 0;
        end
        // Reset pointer when a new I2C transaction starts
        else if (S_AXI_WREADY && S_AXI_WVALID && axi_awready && axi_awaddr == ADDR_CTRL_REG && S_AXI_WDATA[8]) begin
            rx_read_ptr <= 0;
        end
        // Increment pointer when master reads from the RX FIFO
        else if (S_AXI_RREADY && axi_rvalid && axi_araddr == ADDR_RX_DATA_REG) begin
            if (rx_read_ptr < 2048) begin
                rx_read_ptr <= rx_read_ptr + 1;
            end
        end
    end

    // Write data from the core into the RX buffer
    always @(posedge S_AXI_ACLK) begin
        if (core_oRxDataWrEn) begin
            rx_buffer[core_oDataByteAddr] <= core_oRxDataOut;
        end
    end

    // Interrupt Logic
    // Detect rising edge of events from the core
    reg ack_error_d1;
    reg done_d1;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            ack_error_d1 <= 1'b0;
            done_d1      <= 1'b0;
        end else begin
            ack_error_d1 <= core_oStatusReg[0];
            done_d1      <= core_oSequenceDone;
        end
    end

    assign ack_error_event = ~ack_error_d1 & core_oStatusReg[0];
    assign done_event      = ~done_d1 & core_oSequenceDone;

    // Set interrupt status register bits
    always @(posedge S_AXI_ACLK) begin
       if (!S_AXI_ARESETN) begin
           isr <= 0;
       end else begin
           // Priority 1: Clear bits on write
           if (S_AXI_WREADY && S_AXI_WVALID && axi_awready && axi_awaddr == ADDR_ISR_REG) begin
               isr <= isr & ~S_AXI_WDATA[1:0];
           // Priority 2: Set bits on event
           end else begin
               if (ack_error_event) isr[0] <= 1'b1;
               if (done_event)      isr[1] <= 1'b1;
           end
       end
    end

    // Generate the final interrupt signal
    assign interrupt = |(isr & ier);

    // Combine hardware and software reset (both are active-low for the core)
    assign core_nRst = S_AXI_ARESETN & ~sw_reset;

    assign S_AXI_BVALID = axi_bvalid;
    assign S_AXI_BRESP = axi_bresp;
    assign S_AXI_RDATA = axi_rdata;
    assign S_AXI_RRESP = axi_rresp;
    assign S_AXI_RVALID = axi_rvalid;

endmodule