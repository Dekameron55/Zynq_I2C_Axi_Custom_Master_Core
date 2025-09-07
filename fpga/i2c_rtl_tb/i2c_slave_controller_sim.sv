module i2c_slave_controller(
	inout sda,
	input scl,
    input nRst
	);
	
	localparam ADDRESS = 7'h2A;
	
	localparam S_IDLE = 3'd0;
	localparam S_READ_ADDR = 3'd1;
	localparam S_ADDR_ACK = 3'd2;
	localparam S_READ_INDEX = 3'd3;
	localparam S_INDEX_ACK = 3'd4;
	localparam S_READ_DATA = 3'd5;
	localparam S_DATA_ACK = 3'd6;
	localparam S_WRITE_DATA = 3'd7;
	
	reg [2:0] state = S_IDLE;
	reg [6:0] addr_shift_reg;
	reg [7:0] data_shift_reg;
	reg [3:0] bit_counter;
	
    reg       rw_bit;
	// Memory expanded to 1024 bytes
	output reg [7:0] mem [0:2047];
	reg [10:0] index_pointer; // Address pointer widened for 2048-byte memory

	reg sda_out_bit = 0;
	reg sda_enable = 0;
	
	assign sda = (sda_enable == 1) ? sda_out_bit : 1'bz;
	
	always @(negedge sda) begin
		if (scl == 1) begin // START condition
			state <= S_READ_ADDR;
			bit_counter <= 0;
		end
	end
	
	always @(posedge sda) begin
		if (scl == 1) begin // STOP condition
			state <= S_IDLE;
			sda_enable <= 0;
		end
	end
	
    // Input sampling and state transitions on POSITIVE SCL edge
	always @(posedge scl or negedge nRst) begin
        if (!nRst) begin
            state <= S_IDLE;
            bit_counter <= 0;
            index_pointer <= 0;
            for (int i=0; i<2048; i=i+1) begin
                mem[i] <= 8'hAA; // Initialize entire memory
            end
        end else begin
            case(state)
                S_READ_ADDR: begin
                    if (bit_counter < 7) begin // Read 7 address bits
                        addr_shift_reg <= {addr_shift_reg[5:0], sda};
                        bit_counter <= bit_counter + 1;
                    end else begin // After 7 bits, latch R/W bit on the 8th
                        rw_bit <= sda;
                        state <= S_ADDR_ACK;
                    end
                end
                
                S_ADDR_ACK: begin
                    // After ACK cycle, transition based on R/W bit
                    if (addr_shift_reg == ADDRESS) begin
                        bit_counter <= 0;
                        if (rw_bit == 0) begin // Master wants to write
                            state <= S_READ_INDEX;
                        end else begin // Master wants to read
                            data_shift_reg <= mem[index_pointer];
                            state <= S_WRITE_DATA;
                        end
                    end else begin
                        state <= S_IDLE; // Address didn't match
                    end
                end

                S_READ_INDEX: begin
                    if (bit_counter < 7) begin
                        data_shift_reg <= {data_shift_reg[6:0], sda};
                        bit_counter <= bit_counter + 1;
                    end else begin
                        index_pointer <= {data_shift_reg[6:0], sda}; // Latch full byte, then select lower bits
                        state <= S_INDEX_ACK;
                    end
                end

                S_INDEX_ACK: begin
                    state <= S_READ_DATA;
                    bit_counter <= 0;
                end

                S_READ_DATA: begin
                    if (bit_counter < 7) begin
                        data_shift_reg <= {data_shift_reg[6:0], sda};
                        bit_counter <= bit_counter + 1;
                    end else begin
                        mem[index_pointer] <= {data_shift_reg[6:0], sda};
                        index_pointer <= index_pointer + 1;
                        state <= S_DATA_ACK;
                    end
                end

                S_DATA_ACK: begin
                    state <= S_READ_DATA; // Ready for next byte
                    bit_counter <= 0;
                end

                S_WRITE_DATA: begin
                    if (bit_counter < 8) begin // During the 8 data bits
                        bit_counter <= bit_counter + 1;
                    end else begin // After sending 8 bits, this is the ACK/NACK cycle
                        // Check for master's ACK.
                        if (sda == 1) state <= S_IDLE; // Master NACKed, we are done
                        else begin
                            // Master ACKed, stay in this state for the next byte.
                            index_pointer <= index_pointer + 1;
                            data_shift_reg <= mem[index_pointer + 1];
                            bit_counter <= 0;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
	end

    // Output driving on NEGATIVE SCL edge
    always @(negedge scl or negedge nRst) begin
        if (!nRst) begin
            sda_enable <= 0;
        end else begin
            case (state)
                S_ADDR_ACK: begin sda_out_bit <= 0; sda_enable <= 1; end
                S_INDEX_ACK: begin sda_out_bit <= 0; sda_enable <= 1; end
                S_DATA_ACK: begin sda_out_bit <= 0; sda_enable <= 1; end
                S_WRITE_DATA: begin
                    if (bit_counter < 8) begin
                        sda_out_bit <= data_shift_reg[7];
                        data_shift_reg <= data_shift_reg << 1;
                        sda_enable <= 1;
                    end else begin // During ACK/NACK cycle, release the bus
                        sda_enable <= 0;
                    end
                end
                default: sda_enable <= 0;
            endcase
        end
    end
endmodule