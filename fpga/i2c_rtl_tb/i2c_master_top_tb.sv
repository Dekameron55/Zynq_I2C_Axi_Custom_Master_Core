`timescale 1ns / 1ps

module i2c_master_top_tb;
    // Testbench for i2c_master_top
    // Declare signals and wires
    // To run from this directory:
    // Step 1. Compile the .sv/.v files
    // iverilog -g2012 -o design.vvp i2c_master_top_tb.sv i2c_slave_controller_sim.sv ..\i2c_rtl\i2c_master_top.v ..\i2c_rtl\i2c_core.v
    // ..\i2c_rtl\i2c_timer.v
    // Step 2. Run the testbench
    // vvp.exe .\design.vvp 
    // Step 3. Investigate e.g with GtkWave (example tool with preloaded config see rtl_sim_1.png and example output tb_output.txt)
    // gtkwave.exe .\dump.vcd .\setup1.gtkw 

    logic clk;
    reg nRst;
    logic [7:0] iCommand;
    logic [31:0] iQuarterBitCounter;
    logic [11:0] iBytesToWrite;
    reg [11:0] iBytesToRead;
    logic [6:0] iSlaveAddr;
    wire [7:0] oStatusReg;
    logic iStartSequence;
    wire oSequenceDone;
    wire oDataRxDv;

    // Buffer Interface signals
    logic         iTxBufWrEn;
    logic   [7:0] iTxBufDataIn;
    logic         iRxBufRdEn;
    wire    [7:0] oRxBufDataOut;

    wire i_scl;
    wire o_scl;
    wire oe_scl;
    wire i_sda;
    wire o_sda;
    wire oe_sda;

    // Instantiate the i2c_master_top module
    i2c_master_top i2c_master_top_inst (
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
        .iTxBufWrEn(iTxBufWrEn), .iTxBufDataIn(iTxBufDataIn),
        .iRxBufRdEn(iRxBufRdEn), .oRxBufDataOut(oRxBufDataOut),
        .i_scl(i_scl),
        .o_scl(o_scl),
        .oe_scl(oe_scl),
        .i_sda(i_sda),
        .o_sda(o_sda),
        .oe_sda(oe_sda)
    );

    // I2C bus wires
    wire scl_bus;
    wire sda_bus;

    // Instantiate the I2C slave model
    i2c_slave_controller slave (
        .scl(scl_bus),
        .sda(sda_bus),
        .nRst(nRst)
    );

    // Clock generation
    initial clk = 0;
    always #5 clk = ~clk; // 100MHz clock

    // I2C bus pull-up model.
    // SCL is driven by master or pulled high.
    assign scl_bus = (oe_scl) ? o_scl : 1'b1;
    assign i_scl = scl_bus;

    // SDA is a bidirectional wire with a pull-up.
    // Master drives when oe_sda is high. Slave drives through its inout port.
    pullup(sda_bus);
    assign sda_bus = (oe_sda) ? o_sda : 1'bz;
    assign i_sda = sda_bus;

    // Simulation step counter for clearer logging
    integer sim_step;

    // Command definitions to match the i2c_core
    localparam CMD_WRITE            = 2'b01;
    localparam CMD_READ             = 2'b10;
    localparam CMD_WRITE_THEN_READ  = 2'b11;
    localparam SLAVE_REG0_RESET_VAL = 8'hBE; // Value in slave reg 0 at reset

    // Task to simplify writing to the TX buffer. Requires SystemVerilog.
    task write_tx_buffer(input [7:0] data);
        @(posedge clk);
        iTxBufDataIn <= data;
        iTxBufWrEn <= 1;
        @(posedge clk);
        iTxBufWrEn <= 0;
        #1;
    endtask

    // Task to simplify reading from the RX buffer.
    task read_rx_buffer();
        @(posedge clk);
        iRxBufRdEn <= 1;
        @(posedge clk);
        iRxBufRdEn <= 0;
        #1; // Allow combinational logic to settle before checking output
    endtask

    // Task to verify a byte read from the RX buffer.
    task verify_rx_byte(input int index, input logic [7:0] expected_value);
        // For the first byte (index 0), the data is already on the output.
        // For subsequent bytes, we need to pulse the read enable to increment the pointer.
        if (index > 0) begin
            read_rx_buffer();
        end
        if (oRxBufDataOut !== expected_value) begin
            $error("Readback data mismatch on byte %0d! Expected 0x%h, got 0x%h", index, expected_value, oRxBufDataOut);
        end else begin
            $display("SUCCESS: Readback byte %0d is 0x%h as expected.", index, expected_value);
        end
    endtask
    initial begin
      // Required for EDA Playground
      $dumpfile("dump.vcd"); 
      $dumpvars(0, i2c_master_top_tb);

        // 1. Initialize and Reset
        clk = 0;
        sim_step = 10;
        iStartSequence = 0;
        iBytesToRead = 0;
        nRst = 0;
        $display("[%0t] TB Step %0d: Simulation Start. Applying reset.", $time, sim_step);
        #10;
        iTxBufWrEn <= 0;
        iTxBufDataIn <= 0;
        iRxBufRdEn <= 0;
        nRst = 1;
        sim_step = 20;
        $display("[%0t] TB Step %0d: Reset released.", $time, sim_step);

        // Set the core's clock frequency once for all tests
        // SCL Freq = 100MHz / (4 * (iQuarterBitCounter + 1))
        iQuarterBitCounter <= 6; // Set SCL frequency to ~400kHz for a 100MHz clock
        #5000;
       
        // --- TEST 1: Indexed Write to new slave ---
        sim_step = 30;
        $display("[%0t] TB Step %0d: --- Test 1: Write 0xCA to slave mem[2] ---", $time, sim_step);
        write_tx_buffer(8'h02); // Set memory index to 2
        write_tx_buffer(8'hCA); // Write 0xCA to mem[2]
        iBytesToWrite      <= 2;   // Write 2 bytes (index, data)
        iBytesToRead       <= 0;
        iCommand           <= CMD_WRITE;
        iSlaveAddr         <= 7'h2A; // Address of the new slave
        $display("[%0t] TB: Configuring master: iCommand=0x%h, iBytesToWrite=%0d, iBytesToRead=%0d, iSlaveAddr=0x%h", $time, iCommand, iBytesToWrite, iBytesToRead, iSlaveAddr);

        @(posedge clk);
        sim_step = 40;
        $display("[%0t] TB Step %0d: Starting indexed write sequence.", $time, sim_step);
        iStartSequence <= 1;
        @(posedge clk);
        iStartSequence <= 0;

        sim_step = 50;
        $display("[%0t] TB Step %0d: Waiting for indexed write to complete (oSequenceDone)...", $time, sim_step);
        @(posedge oSequenceDone);
        $display("[%0t] TB: Write transaction complete.", $time);

        // Verification
        sim_step = 60;
        $display("[%0t] TB Step %0d: Verifying write. Checking slave's memory.", $time, sim_step);
        if (slave.mem[2] !== 8'hCA) begin
            $error("Slave memory write failed! Expected mem[2]=0xCA, got 0x%h", slave.mem[2]);
        end else begin
            $display("SUCCESS: Slave memory[2] is 0xCA as expected.");
        end
        #3000;

        // --- TEST 2: Multi-byte Write to new slave ---
        sim_step = 70;
        $display("[%0t] TB Step %0d: --- Test 2: Multi-write 2050 bytes to slave mem ---", $time, sim_step);
        write_tx_buffer(8'h00); // Set memory index to 0
        write_tx_buffer(8'hDE); // Write 0xDE to mem[0]
        write_tx_buffer(8'hAD); // Write 0xAD to mem[1]
        write_tx_buffer(8'hBE); // Write 0xBE to mem[2]
        write_tx_buffer(8'hEF); // Write 0xEF to mem[3]
        write_tx_buffer(8'h12); // Write 0x12 to mem[4]
        write_tx_buffer(8'h34); // Write 0x34 to mem[5]        
        // Fill the rest of the buffer with 0x55
        for (int i = 6; i < 2050; i++) begin
            write_tx_buffer(8'h55);
        end        
        iBytesToWrite      <= 2049;   // Write 2049 bytes (1 index + 2048 data bytes)
        iBytesToRead       <= 0;
        iCommand           <= CMD_WRITE;
        iSlaveAddr         <= 7'h2A; // Address of the new slave
        $display("[%0t] TB: Configuring master: iCommand=0x%h, iBytesToWrite=%0d, iBytesToRead=%0d, iSlaveAddr=0x%h", $time, iCommand, iBytesToWrite, iBytesToRead, iSlaveAddr);

        @(posedge clk);
        sim_step = 80;
        $display("[%0t] TB Step %0d: Starting multi-write sequence.", $time, sim_step);
        iStartSequence <= 1;
        @(posedge clk);
        iStartSequence <= 0;

        sim_step = 90;
        $display("[%0t] TB Step %0d: Waiting for multi-write to complete (oSequenceDone)...", $time, sim_step);
        @(posedge oSequenceDone);
        $display("[%0t] TB: Multi-write transaction complete.", $time);

        // Verification
        sim_step = 100;
        $display("[%0t] TB Step %0d: Verifying multi-write. Checking slave's memory.", $time, sim_step);
        if (slave.mem[0] !== 8'hDE || slave.mem[1] !== 8'hAD || slave.mem[2] !== 8'hBE || slave.mem[3] !== 8'hEF || slave.mem[4] !== 8'h12 || slave.mem[5] !== 8'h34) begin
          $error("Slave memory write failed! Expected DE,AD,BE,EF,12,34. Got %h,%h,%h,%h,%h,%h", slave.mem[0], slave.mem[1], slave.mem[2], slave.mem[3], slave.mem[4], slave.mem[5]);
        end else if (slave.mem[1024] !== 8'h55) begin
            $error("Slave memory write failed in middle! Expected mem[1024]=55, got %h", slave.mem[1024]);
        end else if (slave.mem[2047] !== 8'h55) begin
            $error("Slave memory write failed at end! Expected mem[2047]=55, got %h", slave.mem[2047]);
        end else begin
            $display("SUCCESS: Slave memory updated correctly.");
        end
         if (slave.mem[0] !== 8'hDE) begin
             $error("Slave memory write failed! Expected mem[0]=0xDE, got 0x%h", slave.mem[0]);
        end
        #3000;
        
        // --- TEST 3: Multi-byte Read from new slave ---
        sim_step = 110;
        $display("[%0t] TB Step %0d: --- Test 3: Read 2048 bytes from slave memory ---", $time, sim_step);
        write_tx_buffer(8'h00); // Set memory index to 0
        iBytesToWrite      <= 1;
        iBytesToRead       <= 2048;   // Read 2048 bytes of data
        iCommand           <= CMD_WRITE_THEN_READ;
        iSlaveAddr         <= 7'h2A; // Address of the new slave
        $display("[%0t] TB: Configuring master: iCommand=0x%h, iBytesToWrite=%0d, iBytesToRead=%0d, iSlaveAddr=0x%h", $time, iCommand, iBytesToWrite, iBytesToRead, iSlaveAddr);

        @(posedge clk);
        sim_step = 120;
        $display("[%0t] TB Step %0d: Starting simple read sequence.", $time, sim_step);
        iStartSequence <= 1;
        @(posedge clk);
        iStartSequence <= 0;

        sim_step = 130;
        $display("[%0t] TB Step %0d: Waiting for simple read to complete (oSequenceDone)...", $time, sim_step);
        @(posedge oSequenceDone);
        $display("[%0t] TB: Read transaction complete.", $time);


        // Verification
        sim_step = 140;
        $display("[%0t] TB Step %0d: Verifying multi-byte read. Checking RX buffer.", $time, sim_step);

        // Use the verification task to check the first few bytes.
        verify_rx_byte(0, 8'hDE);
        verify_rx_byte(1, 8'hAD);
        verify_rx_byte(2, 8'hBE);
        verify_rx_byte(3, 8'hEF);
        verify_rx_byte(4, 8'h12);
        verify_rx_byte(5, 8'h34);
        // Spot check one more byte to ensure the 0x55 pattern was read.
        verify_rx_byte(6, 8'h55);
        $display("SUCCESS: First 7 bytes of readback are correct. Assuming the rest of the 2048-byte transfer is also correct.");

        #3000;
       
        // --- TEST 4: NACK on invalid slave address ---
        sim_step = 150;
        $display("[%0t] TB Step %0d: --- Test 6: NACK on invalid slave address ---", $time, sim_step);
        write_tx_buffer(8'h00); // Dummy data for the buffer
        iBytesToWrite      <= 1;   // Only need to write the address to get a NACK
        iBytesToRead       <= 0;
        iCommand           <= CMD_WRITE;
        iSlaveAddr         <= 7'h2B; // This address does not exist
        $display("[%0t] TB: Configuring master: iCommand=0x%h, iBytesToWrite=%0d, iBytesToRead=%0d, iSlaveAddr=0x%h", $time, iCommand, iBytesToWrite, iBytesToRead, iSlaveAddr);

        @(posedge clk);
        sim_step = 160;
        $display("[%0t] TB Step %0d: Starting sequence to invalid address.", $time, sim_step);
        iStartSequence <= 1;
        @(posedge clk);
        iStartSequence <= 0;

        sim_step = 170;
        $display("[%0t] TB Step %0d: Waiting for NACK transaction to complete (oSequenceDone)...", $time, sim_step);
        @(posedge oSequenceDone);
        $display("[%0t] TB: NACK transaction complete.", $time);

        sim_step = 180;
        $display("[%0t] TB Step %0d: Verifying NACK. Checking status register.", $time, sim_step);
        if (oStatusReg[0] !== 1'b1) begin
            $error("NACK test failed! Expected ACK error bit (oStatusReg[0]) to be 1, but it was 0.");
        end else begin
            $display("SUCCESS: ACK error bit is 1 as expected after addressing non-existent slave.");
        end

        sim_step = 190;
        $display("[%0t] TB Step %0d: Simulation End.", $time, sim_step);
        
        #1000;
        $finish();
    end
endmodule
