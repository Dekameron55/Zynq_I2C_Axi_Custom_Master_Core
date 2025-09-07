module i2c_core(
input clk,
input nRst, // Active-low asynchronous reset

//Configuration Registers for the core.
input  [7:0] iCommand,
input  [31:0] iQuarterBitCounter,
input  [11:0] iBytesToWrite,
input  [11:0] iBytesToRead,

// Slave Address
input   [6:0] iSlaveAddr,

// TX/RX Buffer Interface
output  [11:0] oDataByteAddr,
input   [7:0] iTxData,
output  reg   oRxDataWrEn,
output  [7:0] oRxDataOut,

//Sync registers
output  [7:0] oStatusReg,
input  iStartSequence,
output  reg oSequenceDone,
output wire oDataRxDv,

input  iCounterDone, // This input is unused in the core logic.

//Physical level wires
input wire i_scl,
output reg o_scl,
output reg oe_scl,

input wire i_sda,
output reg o_sda,
output reg oe_sda
);


    parameter IDLE      = 3'b000;

    // Unified FSM states representing each quarter-phase of the I2C protocol
    localparam FSM_IDLE         = 5'h00;
    localparam FSM_START_P1     = 5'h01;
    localparam FSM_START_P2     = 5'h02;
    localparam FSM_DATA_P1_SETUP= 5'h03;
    localparam FSM_DATA_P2_SCL_H= 5'h04;
    localparam FSM_DATA_P3_SCL_L= 5'h05;
    localparam FSM_ACK_P1_SETUP = 5'h06;
    localparam FSM_ACK_P2_SCL_H = 5'h07;
    localparam FSM_ACK_P3_SCL_L = 5'h08;
    localparam FSM_ACK_P4_CHECK = 5'h09;
    localparam FSM_STOP_P1_SETUP= 5'h0A; // SCL low, SDA low
    localparam FSM_STOP_P2_SCL_H= 5'h0B; // SCL high, SDA low
    localparam FSM_STOP_P3_SDA_H= 5'h0C; // SCL high, SDA high (STOP)
    localparam FSM_STOP_P4_FINAL= 5'h0D; // Final state before IDLE
    localparam FSM_ACK_P3_RELEASE = 5'h0E; // New state for robust ACK timing
    localparam FSM_DATA_P4_SCL_L_WAIT = 5'h0F; // New state to ensure 4-tick data period
    localparam FSM_START_P3_WAIT = 5'h10; // New state for extra start hold time
    localparam FSM_REPEATED_START_SETUP = 5'h11; // New state to add delay before a repeated start

    // Status Register bit definitions
    localparam STATUS_REG_ACK_ERROR_BIT = 0;
    localparam STATUS_REG_IDLE_BIT      = 1;

    // Command Register bit definitions
    localparam CMD_WRITE            = 2'b01;
    localparam CMD_READ             = 2'b10;
    localparam CMD_WRITE_THEN_READ  = 2'b11;

    // Internal state and control signals
    reg [4:0] state = FSM_IDLE;
    reg [4:0] next_state;

    reg [3:0] bit_count = 0; // Counts bits within a byte transfer (0-7)
    reg [11:0] byte_count = 0; // Counts bytes in a transaction

    // Data path registers
    reg [7:0] tx_shift_reg; // Holds address/data for transmission
    reg [7:0] DataRx_r = 0;
    reg DataRxDv_r = 0;

    reg [11:0] data_byte_count = 0; // Counts data bytes in a transaction

    reg ack_error = 0;
    reg [7:0] status_reg = 0; // Status register

    // Control signals for sub-modules
    reg startCounting = 0;

    reg rw_mode = 1'b0; // 0 for write, 1 for read
    // Internal wires
    wire ack_bit;
    wire tx_bit;
    wire oCounterDone;

    // Synchronizers for asynchronous inputs to prevent metastability
    reg i_sda_sync1, i_sda_sync2;
    wire sda_sync;
    reg iStartSequence_sync1, iStartSequence_sync2;
    wire start_pulse;

    // The bit to be driven on SDA during a write operation
    assign tx_bit = tx_shift_reg[7];

    // Sample the ACK bit from the slave at the correct time.
    // This is sampled synchronously when SCL is high in the FSM_ACK_P2_SCL_H state.
    assign ack_bit = i_sda;
    assign sda_sync = i_sda_sync2;

    // Assign outputs
    assign oDataRxDv = DataRxDv_r;
    // For writes, use data_byte_count-1. For reads, use byte_count-1.
    assign oDataByteAddr = (rw_mode == 1'b0) ? (data_byte_count) : (byte_count - 1);
    assign oRxDataOut = DataRx_r;
    assign oStatusReg = {status_reg[7:2], (state == FSM_IDLE), status_reg[0]};

    // iCounterStop is an input to the core but never driven.
    // iQuarterBitCounter is an input but not used. The timer target is hardcoded.
    // This should be corrected for a flexible design.
    i2c_timer timer (
        .clk(clk),
        .nRst(nRst),
        .iCounterReset(1'b1), // Disable synchronous reset, rely on nRst
        .iCounterStart(startCounting),
        .iCounterStop(1'b0), // Assuming no stop condition from core for now
        .iCounterTarget(iQuarterBitCounter), // Use the configuration input
        .oCounterDone(oCounterDone)
    );

    // Two-flop synchronizers for asynchronous inputs
    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            i_sda_sync1 <= 1'b0;
            i_sda_sync2 <= 1'b0;
            iStartSequence_sync1 <= 1'b0;
            iStartSequence_sync2 <= 1'b0;
        end else begin
            {i_sda_sync1, i_sda_sync2} <= {i_sda, i_sda_sync1};
            {iStartSequence_sync1, iStartSequence_sync2} <= {iStartSequence, iStartSequence_sync1};
        end
    end
    assign start_pulse = ~iStartSequence_sync2 && iStartSequence_sync1; // Detect rising edge

    // FSM Sequential Block: Registers state and other sequential logic
    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            state <= FSM_IDLE;
            bit_count <= 0;
            byte_count <= 0;
            oSequenceDone <= 1'b0;
            DataRx_r <= 0;
            DataRxDv_r <= 1'b0;
            rw_mode <= 1'b0; // Initialize to a safe default
            oRxDataWrEn <= 1'b0;
            data_byte_count <= 0;
            ack_error <= 1'b0;
            status_reg <= 0; // Reset status register
            o_scl <= 1'b1;
            oe_scl <= 1'b0;
            o_sda <= 1'b1;
            oe_sda <= 1'b0;

            // Default assignments for physical outputs
            o_scl <= 1'b1;
            oe_scl <= 1'b0;
        end else begin
            // Default behavior: hold data valid for one cycle
            DataRxDv_r <= 1'b0;
            oRxDataWrEn <= 1'b0;

            // On iStartSequence, clear flags and pre-load the first data chunk
            if (start_pulse) begin
                ack_error <= 1'b0;
                status_reg[STATUS_REG_ACK_ERROR_BIT] <= 1'b0; // Clear only the ACK error bit
                byte_count <= 0;
                bit_count <= 0;
                data_byte_count <= 0;

                // Determine initial rw_mode and tx_shift_reg based on command
                case (iCommand[1:0])
                    CMD_WRITE, CMD_WRITE_THEN_READ: begin
                        rw_mode <= 1'b0; // Start with a write
                        tx_shift_reg <= {iSlaveAddr, 1'b0}; // Slave addr + Write bit
                    end
                    CMD_READ: begin
                        rw_mode <= 1'b1; // Start with a read
                        tx_shift_reg <= {iSlaveAddr, 1'b1}; // Slave addr + Read bit
                    end
                    default: begin // Default to a safe state (e.g., write)
                        rw_mode <= 1'b0;
                        tx_shift_reg <= {iSlaveAddr, 1'b0};
                    end
                endcase
            end

            // All state and data updates are enabled by the timer tick
            if (oCounterDone || start_pulse) begin
                state <= next_state;

                // Update physical outputs based on the FSM's next state logic
                {o_scl, oe_scl} <= next_state_outputs_scl;
                {o_sda, oe_sda} <= next_state_outputs_sda;

                // Shift transmit register if master is driving the bus
                if (state == FSM_DATA_P4_SCL_L_WAIT) begin // Shift at the end of the bit cycle
                    bit_count <= bit_count + 1;
                    // Shift if in a write cycle, or during the address phase of a read cycle.
                    if (rw_mode == 1'b0 || (rw_mode == 1'b1 && byte_count == 0)) begin
                        tx_shift_reg <= tx_shift_reg << 1;
                    end
                end

                if (state == FSM_ACK_P4_CHECK) begin // After checking ACK
                    bit_count <= 0;
                    byte_count <= byte_count + 1;

                    // If we are about to transfer a data byte, increment the data counter
                    if (next_state == FSM_DATA_P1_SETUP) begin
                        data_byte_count <= data_byte_count + 1;
                    end

                    // Pre-load next data byte from TX buffer if needed
                    if (next_state == FSM_DATA_P1_SETUP) begin
                        if (rw_mode == 1'b0) begin
                           tx_shift_reg <= iTxData;
                        end
                    end

                    // Check for transition from write to read (repeated start)
                    if (next_state == FSM_REPEATED_START_SETUP) begin
                        rw_mode <= 1'b1; // The next transaction is a read
                        byte_count <= 0; // Reset byte count for the read phase
                        data_byte_count <= 0; // Reset data byte count for read phase
                        tx_shift_reg <= {iSlaveAddr, 1'b1}; // Load slave addr with R/W=1
                    end
                end

                // Sample read data
                if (state == FSM_DATA_P2_SCL_H && rw_mode == 1'b1 && byte_count > 0) begin
                    DataRx_r <= {DataRx_r[6:0], sda_sync};
                end

                // Latch ACK error
                // A NACK is an error if the master is driving the bus. This occurs when:
                // 1. Sending an address byte (for write or read), when byte_count is 0.
                // 2. Sending a data byte during a write transaction (rw_mode is 0).
                if (state == FSM_ACK_P2_SCL_H && ack_bit == 1'b1 && (rw_mode == 1'b0 || byte_count == 0)) begin
                    ack_error <= 1'b1;
                    status_reg[STATUS_REG_ACK_ERROR_BIT] <= 1'b1; // Set the ACK error status bit
                end

                // Set data valid flag and store received byte after the 8th bit is clocked in.
                // This is more robust than tying it to the ACK/NACK FSM states.
                if (state == FSM_DATA_P3_SCL_L && bit_count == 7 && rw_mode == 1'b1 && byte_count > 0) begin
                    DataRxDv_r <= 1'b1;
                    oRxDataWrEn <= 1'b1; // This was the source of the error
                end

                // Set sequence done flag
                if (next_state == FSM_IDLE && state != FSM_IDLE) begin
                    oSequenceDone <= 1'b1;
                end else if (start_pulse) begin
                    oSequenceDone <= 1'b0;
                end
            end
        end
    end

    // Regs to hold the combinatorial output values for the registered outputs
    reg [1:0] next_state_outputs_scl;
    reg [1:0] next_state_outputs_sda;

    // FSM Combinatorial Block: Determines next state and outputs
    always @(*) begin
        // Default assignments to prevent latches
        next_state = state;
        next_state_outputs_scl = 2'b10; // Default to bus released (high-Z)
        next_state_outputs_sda = 2'b10;

        startCounting = 1'b0;

        case (state)
            FSM_IDLE: begin
                if (start_pulse) begin
                    next_state = FSM_START_P1;
                end
            end

            FSM_START_P1: begin // SCL high, pull SDA low
                next_state_outputs_scl = 2'b11;
                next_state_outputs_sda = 2'b01;
                startCounting = 1'b1;
                next_state = FSM_START_P2;
            end

            FSM_START_P2: begin // SCL low, SDA low
                next_state_outputs_scl = 2'b01;
                next_state_outputs_sda = 2'b01;
                startCounting = 1'b1;
                next_state = FSM_START_P3_WAIT; // Go to new wait state
            end

            FSM_DATA_P1_SETUP: begin // SCL low, set SDA
                next_state_outputs_scl = 2'b01;
                startCounting = 1'b1;
                // During a read transaction (rw_mode==1), the master only releases the bus
                // to read data bytes. It must drive the bus for the address byte (when byte_count is 0).
                if (rw_mode == 1'b1 && byte_count > 0) begin
                    next_state_outputs_sda = 2'b10; // Release bus for slave to drive
                end else begin
                    next_state_outputs_sda = {tx_bit, 1'b1};
                end
                next_state = FSM_DATA_P2_SCL_H;
            end

            FSM_DATA_P2_SCL_H: begin // SCL high, hold SDA
                next_state_outputs_scl = 2'b11;
                startCounting = 1'b1;
                // Keep bus state consistent through SCL high phase
                if (rw_mode == 1'b1 && byte_count > 0) begin
                    next_state_outputs_sda = 2'b10; // Keep bus released
                end else begin
                    next_state_outputs_sda = {tx_bit, 1'b1};
                end
                next_state = FSM_DATA_P3_SCL_L;
            end

            FSM_DATA_P3_SCL_L: begin // SCL high (Quarter 3 of 4), hold SDA
                next_state_outputs_scl = 2'b11; // SCL is high for 2nd quarter
                startCounting = 1'b1;
                // Keep bus state consistent through SCL high phase
                if (rw_mode == 1'b1 && byte_count > 0) begin
                    next_state_outputs_sda = 2'b10; // Keep bus released
                end else begin
                    next_state_outputs_sda = {tx_bit, 1'b1};
                end
                next_state = FSM_DATA_P4_SCL_L_WAIT; // Go to new wait state
            end

            FSM_ACK_P1_SETUP: begin // SCL low, prepare for ACK/NACK
                next_state_outputs_scl = 2'b01;
                // Master expects an ACK from slave after sending an address (byte_count==0) or during a write.
                if (rw_mode == 1'b0 || byte_count == 0) begin
                    next_state_outputs_sda = 2'b10; // Release SDA
                end else begin // Master is sending ACK/NACK to slave
                    // Send ACK if more bytes to read, NACK if this is the last one
                    // The master must NACK the final byte it intends to read.
                    if (byte_count < iBytesToRead) begin
                        next_state_outputs_sda = 2'b01; // Master drives SDA for ACK (ACK = 0)
                    end else begin
                        next_state_outputs_sda = 2'b10; // Release bus for NACK
                    end
                end
                startCounting = 1'b1;
                next_state = FSM_ACK_P2_SCL_H;
            end

            FSM_ACK_P2_SCL_H: begin // SCL high, sample or hold ACK/NACK
                next_state_outputs_scl = 2'b11;
                if (rw_mode == 1'b0 || byte_count == 0) begin
                    next_state_outputs_sda = 2'b10; // Keep SDA released
                end else begin // Master is sending ACK/NACK to slave
                    if (byte_count < iBytesToRead) begin
                        next_state_outputs_sda = 2'b01; // Keep driving SDA for ACK
                    end else begin
                        next_state_outputs_sda = 2'b10; // Keep bus released for NACK
                    end
                end
                startCounting = 1'b1;
                next_state = FSM_ACK_P3_SCL_L;
            end

            FSM_ACK_P3_SCL_L: begin // SCL high (Quarter 3 of 4), hold ACK/NACK
                next_state_outputs_scl = 2'b11; // SCL is high for 2nd quarter
                startCounting = 1'b1;
                next_state = FSM_ACK_P3_RELEASE; // Go to the new release state

                // Keep driving/releasing SDA for the ACK/NACK
                if (rw_mode == 1'b0 || byte_count == 0) begin
                    next_state_outputs_sda = 2'b10; // Keep SDA released
                end else begin // Master was sending ACK/NACK to slave
                    if (byte_count < iBytesToRead) begin
                        next_state_outputs_sda = 2'b01; // Keep driving SDA for ACK
                    end else begin
                        next_state_outputs_sda = 2'b10; // Keep bus released for NACK
                    end
                end
            end

            FSM_ACK_P3_RELEASE: begin // New state to release the bus
                next_state_outputs_scl = 2'b01; // Keep SCL low
                next_state_outputs_sda = 2'b10; // Now release the bus
                startCounting = 1'b1;
                next_state = FSM_ACK_P4_CHECK; // Proceed to the check state
            end

            FSM_ACK_P4_CHECK: begin // Control state to decide next action
                next_state_outputs_scl = 2'b01;
                startCounting = 1'b1;
                if (ack_error) begin
                    next_state = FSM_STOP_P1_SETUP;
                // Are we in a write phase?
                end else if (rw_mode == 1'b0) begin
                    // Have we written all the data bytes for this phase?
                    if (data_byte_count < iBytesToWrite) begin
                        next_state = FSM_DATA_P1_SETUP;
                    // Write phase is done, is there a read phase to follow?
                    end else if (iCommand[1:0] == CMD_WRITE_THEN_READ) begin
                        next_state = FSM_REPEATED_START_SETUP; // Go to dedicated setup state for delay
                    // No read phase, so we are done.
                    end else begin
                        next_state = FSM_STOP_P1_SETUP;
                    end
                // Are we in a read phase?
                end else begin
                    // For reads, byte_count tracks the number of bytes received.
                    // byte_count includes the address byte, so we must add 1 to the comparison.
                    if (byte_count < (iBytesToRead)) begin
                        next_state = FSM_DATA_P1_SETUP;
                    end else begin
                        next_state = FSM_STOP_P1_SETUP;
                    end
                end
            end

            FSM_STOP_P1_SETUP: begin // SCL is already low, pull SDA low to prepare for STOP
                next_state_outputs_scl = 2'b01;
                next_state_outputs_sda = 2'b01;
                startCounting = 1'b1;
                next_state = FSM_STOP_P2_SCL_H;
            end

            FSM_STOP_P2_SCL_H: begin // Raise SCL while SDA is low
                next_state_outputs_scl = 2'b11;
                next_state_outputs_sda = 2'b01;
                startCounting = 1'b1;
                next_state = FSM_STOP_P3_SDA_H;
            end

            FSM_STOP_P3_SDA_H: begin // Raise SDA while SCL is high (STOP condition)
                next_state_outputs_scl = 2'b11;
                next_state_outputs_sda = 2'b11;
                startCounting = 1'b1;
                next_state = FSM_STOP_P4_FINAL;
            end

            FSM_START_P3_WAIT: begin // SCL low, SDA low (extra hold time)
                next_state_outputs_scl = 2'b01;
                next_state_outputs_sda = 2'b01;
                startCounting = 1'b1;
                next_state = FSM_DATA_P1_SETUP;
            end

            FSM_DATA_P4_SCL_L_WAIT: begin // SCL low, wait state to complete 4-tick period
                next_state_outputs_scl = 2'b01;

                // Hold the bus state from the previous state. Do not release unconditionally.
                if ( (rw_mode == 1'b1 && byte_count > 0) ||                                  // Case 1: Master is receiving data
                     (bit_count == 7 && (rw_mode == 1'b0 || byte_count == 0)) ) begin        // Case 2: Master just sent a byte
                    next_state_outputs_sda = 2'b10; // Release bus
                end else begin
                    next_state_outputs_sda = {tx_bit, 1'b1}; // Continue driving
                end

                startCounting = 1'b1;
                // Now decide where to go next based on bit count
                next_state = (bit_count == 7) ? FSM_ACK_P1_SETUP : FSM_DATA_P1_SETUP;
            end

            FSM_STOP_P4_FINAL: begin // Hold bus released, transition to IDLE
                startCounting = 1'b1; // Allow one more tick to transition to IDLE
                next_state = FSM_IDLE;
            end

            FSM_REPEATED_START_SETUP: begin // Release bus to prepare for repeated start
                next_state_outputs_scl = 2'b10; // Release SCL to let it be pulled high
                next_state_outputs_sda = 2'b10; // Release SDA to let it be pulled high
                startCounting = 1'b1;
                next_state = FSM_START_P1;  // Now we are ready for the start condition
            end
        endcase
    end

endmodule
