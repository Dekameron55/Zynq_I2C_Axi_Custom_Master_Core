`timescale 1ns / 1ps

// Import the necessary AXI VIP packages. The second package name is
// specific to your block design and will be found in the Vivado IP sources.
import axi_vip_pkg::*;
import i2c_axi_custom_axi_vip_0_0_pkg::*;

module i2c_axi_vip_tb;

    // Clock and Reset
    bit aclk = 0;
    bit aresetn = 0;

    // I2C bus wires
    wire scl_bus;
    wire sda_bus;

    // Instantiate the Block Design Wrapper from Vivado
    // This wrapper should contain your AXI I2C Master IP.
    // Ensure the I2C pins (scl_i, scl_o, scl_t, sda_i, sda_o, sda_t) are
    // made external in the block design.
    i2c_axi_custom_wrapper DUT (
        .aclk_0(aclk),
        .aresetn_0(aresetn),
        .SCL(scl_bus),
        .SDA(sda_bus)
    );

    // Instantiate the AXI VIP as a Master Agent
    //design_1_axi_vip_0_0_mst_t master_agent;
//i2c_axi_custom_axi_vip_0_0_pkg
//    design_1_axi_vip_0_0_mst_t master_agent;
    i2c_axi_custom_axi_vip_0_0_mst_t master_agent;

    // Instantiate the I2C slave model
    i2c_slave_controller slave (
        .scl(scl_bus),
        .sda(sda_bus),
        .nRst(aresetn)
    );

    // I2C Bus Connection Logic
    // This models the open-drain nature of I2C with pull-up resistors.

    pullup(scl_bus);
    pullup(sda_bus);

    // Clock and Reset Generation
    always #5 aclk = ~aclk; // 100MHz clock

    initial begin
        aresetn = 1'b0;
        #100;
        aresetn = 1'b1;
    end

    // AXI VIP and Testbench Logic
    xil_axi_prot_t prot = 0;
    xil_axi_resp_t resp;

    // Testbench-level variables for holding read data
    bit [31:0] rx_data;
    bit [31:0] dummy_read_data;
    bit [31:0] version_data;
    bit [31:0] isr_data;
    logic [7:0] expected_data;

    // Simulation step counter for clearer logging
    integer sim_step;

    // I2C Core Address Map
    localparam bit [31:0] ADDR_CTRL_REG        = 32'h44A00000;
    localparam bit [31:0] ADDR_STATUS_REG      = 32'h44A00004;
    localparam bit [31:0] ADDR_SLAVE_ADDR_REG  = 32'h44A00008;
    localparam bit [31:0] ADDR_BYTES_WRITE_REG = 32'h44A0000C;
    localparam bit [31:0] ADDR_BYTES_READ_REG  = 32'h44A00010;
    localparam bit [31:0] ADDR_PRESCALER_REG   = 32'h44A00014;
    localparam bit [31:0] ADDR_IER_REG         = 32'h44A00018; // Interrupt Enable Register
    localparam bit [31:0] ADDR_ISR_REG         = 32'h44A0001C; // Interrupt Status Register
    localparam bit [31:0] ADDR_VERSION_REG     = 32'h44A00024; // Version Register
    localparam bit [31:0] ADDR_DUMMY_REG       = 32'h44A00020; // Dummy R/W register for debug
 
    localparam bit [31:0] ADDR_TX_DATA_REG     = 32'h44A00040;
    localparam bit [31:0] ADDR_RX_DATA_REG     = 32'h44A00080;

    // I2C Command Definitions
    localparam bit [31:0] CMD_WRITE           = 32'h01;
    localparam bit [31:0] CMD_READ            = 32'h02;
    localparam bit [31:0] CMD_WRITE_THEN_READ = 32'h03;
    localparam bit [31:0] START_BIT           = 32'h100;

    // Test parameters
    localparam int BLOCK_SIZE = 10;

    // Task to write to a register
    task write_reg(input bit [31:0] addr, input bit [31:0] data);
        begin
        master_agent.AXI4LITE_WRITE_BURST(addr, prot, data, resp);
        end
    endtask

    // Task to read from a register
    task read_reg(input bit [31:0] addr, ref bit [31:0] data);
        // This task is now more robust. It calls the blocking VIP task
        // and then waits for one clock cycle before returning. This ensures
        // the data has time to propagate back to the testbench variable.
        master_agent.AXI4LITE_READ_BURST(addr, prot, data, resp);
        @(posedge aclk);
    endtask

    // Task to wait for the I2C transaction to complete
    task wait_for_done();
        bit [31:0] status;
        $display("TB: Waiting for transaction to complete...");
        do begin
            #1000; // Poll every 1us
            read_reg(ADDR_STATUS_REG, status);
        // Loop while the 'Done' bit (bit 1) is low.
        end while (~status[1]);
    endtask

    // Main test sequence
    initial begin

        // 1. Create and start the AXI master agent
        master_agent = new("master vip agent", DUT.i2c_axi_custom_i.axi_vip_0.inst.IF);
        master_agent.start_master();
        sim_step = 10;
        $display("[%0t] TB Step %0d: Waiting for reset to release...", $time, sim_step);
        wait(aresetn); // Wait for reset to de-assert
        sim_step = 20;
        $display("[%0t] TB Step %0d: Reset released. Starting test sequence.", $time, sim_step);

        // --- Sanity Check: Test Dummy Register ---
        sim_step = 30;
        $display("[%0t] TB Step %0d: --- Sanity Check: Testing Dummy Register ---", $time, sim_step);
        write_reg(ADDR_DUMMY_REG, 32'hDEADBEEF);
        // Calling the VIP method directly to debug the read path
        master_agent.AXI4LITE_READ_BURST(ADDR_DUMMY_REG, prot, dummy_read_data, resp);
        // Wait for one clock cycle for the read data to propagate back to the testbench variable
        @(posedge aclk); 
        if (dummy_read_data !== 32'hDEADBEEF) begin
            $error("Dummy Register test FAILED! Wrote 0xDEADBEEF, read back 0x%h", dummy_read_data);
        end else begin
            $display("SUCCESS: Dummy Register test passed. AXI R/W is working.");
        end
        #1000;

        // --- Sanity Check: Read Version Register ---
        sim_step = 40;
        $display("[%0t] TB Step %0d: --- Sanity Check: Reading Version Register ---", $time, sim_step);
        read_reg(ADDR_VERSION_REG, version_data);
        if (version_data !== 32'h0001_0200) begin
            $error("Version Register test FAILED! Expected 0x00010000, read back 0x%h", version_data);
        end else begin
            $display("SUCCESS: Version Register test passed. Read back 0x%h.", version_data);
        end
        #1000;

        // 2. Configure the I2C Master
        sim_step = 50;
        $display("[%0t] TB Step %0d: Configuring I2C Master...", $time, sim_step);
        write_reg(ADDR_PRESCALER_REG, 61); // Set SCL to ~400kHz
        write_reg(ADDR_SLAVE_ADDR_REG, 7'h2A); // Set slave address
        write_reg(ADDR_IER_REG, 32'h3); // Enable both 'Done' (bit 1) and 'ACK Error' (bit 0) interrupts

        // 3. Perform a simple 2-byte write transaction
        sim_step = 60;
        $display("[%0t] TB Step %0d: --- Test 1: Indexed Write ---", $time, sim_step);
        // Load the TX FIFO
        write_reg(ADDR_TX_DATA_REG, 8'h05); // Memory index
        write_reg(ADDR_TX_DATA_REG, 8'hBB); // Data
        // Configure the transaction
        write_reg(ADDR_BYTES_WRITE_REG, 2); // 2 bytes to write
        write_reg(ADDR_BYTES_READ_REG, 0);
        // Start the transaction
        write_reg(ADDR_CTRL_REG, CMD_WRITE | START_BIT);

        // Wait for completion
        wait_for_done();
        $display("TB: Indexed write complete.");

        // Check and clear the ISR 'Done' bit
        sim_step = 65;
        $display("[%0t] TB Step %0d: Checking and clearing ISR after Test 1...", $time, sim_step);
        read_reg(ADDR_ISR_REG, isr_data);
        if (isr_data[1] !== 1'b1) $error("ISR 'Done' bit not set after Test 1. ISR=0x%h", isr_data);
        else $display("SUCCESS: ISR 'Done' bit is set after Test 1.");
        write_reg(ADDR_ISR_REG, 32'h2); // Clear 'Done' bit
        read_reg(ADDR_ISR_REG, isr_data);
        if (isr_data[1] !== 1'b0) $error("ISR 'Done' bit not cleared after Test 1. ISR=0x%h", isr_data);
        else $display("SUCCESS: ISR 'Done' bit is cleared after Test 1.");

        // Verification (optional, can check slave memory directly)
        if (slave.mem[5] !== 8'hBB) begin
            $error("Slave memory check failed! Expected 0xBB, got 0x%h", slave.mem[5]);
        end else begin
            $display("SUCCESS: Slave memory mem[5] is 0xBB.");
        end
        
        #10_000;

        // 4. Write and Read Back a Full Block of Data
        sim_step = 70;
        $display("[%0t] TB Step %0d: --- Test 3: Writing a %0d-byte block to slave ---", $time, sim_step, BLOCK_SIZE);
        // Load TX FIFO with an address index and then the data block
        write_reg(ADDR_TX_DATA_REG, 8'h00); // Start writing at slave memory index 0
        for (int i = 0; i < BLOCK_SIZE; i++) begin
            write_reg(ADDR_TX_DATA_REG, 8'hC0 + i);
        end
        // Configure and start the write transaction
        write_reg(ADDR_BYTES_WRITE_REG, BLOCK_SIZE + 1); // +1 for the index byte
        write_reg(ADDR_BYTES_READ_REG, 0);
        write_reg(ADDR_CTRL_REG, CMD_WRITE | START_BIT);
        wait_for_done();
        $display("TB: Block write complete.");

        // Check and clear the ISR 'Done' bit
        sim_step = 75;
        $display("[%0t] TB Step %0d: Checking and clearing ISR after Block Write...", $time, sim_step);
        read_reg(ADDR_ISR_REG, isr_data);
        if (isr_data[1] !== 1'b1) $error("ISR 'Done' bit not set after Block Write. ISR=0x%h", isr_data);
        else $display("SUCCESS: ISR 'Done' bit is set after Block Write.");
        write_reg(ADDR_ISR_REG, 32'h2); // Clear 'Done' bit
        read_reg(ADDR_ISR_REG, isr_data);
        if (isr_data[1] !== 1'b0) $error("ISR 'Done' bit not cleared after Block Write. ISR=0x%h", isr_data);
        else $display("SUCCESS: ISR 'Done' bit is cleared after Block Write.");
        #10_000;

        sim_step = 80;
        $display("[%0t] TB Step %0d: --- Reading back %0d-byte block from slave ---", $time, sim_step, BLOCK_SIZE);
        // Set the memory index to read from (index 0)
        write_reg(ADDR_TX_DATA_REG, 8'h00);
        // Configure and start the read transaction
        write_reg(ADDR_BYTES_WRITE_REG, 1);        // Write 1 byte (the index)
        write_reg(ADDR_BYTES_READ_REG, BLOCK_SIZE); // Read BLOCK_SIZE bytes
        write_reg(ADDR_CTRL_REG, CMD_WRITE_THEN_READ | START_BIT);
        wait_for_done();
        $display("TB: Block read complete.");

        // Check and clear the ISR 'Done' bit
        sim_step = 85;
        $display("[%0t] TB Step %0d: Checking and clearing ISR after Block Read...", $time, sim_step);
        read_reg(ADDR_ISR_REG, isr_data);
        if (isr_data[1] !== 1'b1) $error("ISR 'Done' bit not set after Block Read. ISR=0x%h", isr_data);
        else $display("SUCCESS: ISR 'Done' bit is set after Block Read.");
        write_reg(ADDR_ISR_REG, 32'h2); // Clear 'Done' bit
        read_reg(ADDR_ISR_REG, isr_data);
        if (isr_data[1] !== 1'b0) $error("ISR 'Done' bit not cleared after Block Read. ISR=0x%h", isr_data);
        else $display("SUCCESS: ISR 'Done' bit is cleared after Block Read.");

        // Verify the data read back from the RX FIFO
        for (int i = 0; i < BLOCK_SIZE; i++) begin
            read_reg(ADDR_RX_DATA_REG, rx_data);
            expected_data = 8'hC0 + i;
            if (rx_data[7:0] !== expected_data) begin
                $error("Block readback data mismatch at index %0d! Expected 0x%h, got 0x%h", i, expected_data, rx_data[7:0]);
            end
        end
        $display("SUCCESS: Block readback of %0d bytes verified correctly.", BLOCK_SIZE);
        #10_000;
        
        sim_step = 90;
        $display("[%0t] TB Step %0d: All tests passed. Finishing simulation.", $time, sim_step);
        
        $finish;
        end

endmodule