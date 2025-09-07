module i2c_timer(
    input wire clk,
    input wire nRst,

    input wire iCounterReset,
    input wire iCounterStart,
    input wire iCounterStop,

    input wire [31:0] iCounterTarget,

    output reg oCounterDone
);

    reg [31:0] Counter = 0;

    always @(posedge clk or negedge nRst) begin
        if (!nRst) begin
            Counter <= 0;
            oCounterDone <= 0;
        end else begin
            if (!iCounterReset) begin
                Counter <= 0;
                oCounterDone <= 0;
            end else if (iCounterStop) begin
                oCounterDone <= 0;
            end else if (iCounterStart) begin
                if (Counter == iCounterTarget) begin
                    oCounterDone <= 1;
                    Counter <= 0;
                end else begin
                    Counter <= Counter + 1;
                    oCounterDone <= 0;
                end
            end
        end
    end

endmodule