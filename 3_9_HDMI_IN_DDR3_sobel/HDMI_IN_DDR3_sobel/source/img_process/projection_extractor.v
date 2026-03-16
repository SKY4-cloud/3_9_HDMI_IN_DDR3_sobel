`timescale 1ns / 1ps

// =====================================================================
// 模块名称：projection_extractor (硬件直方图投影与边界提取器)
// 架构师解析：利用 BRAM 零延迟统计 X/Y 轴投影，并在消隐区锁定车牌边界
// =====================================================================
module projection_extractor #(
    parameter IMG_WIDTH  = 200,
    parameter IMG_HEIGHT = 100,
    parameter THRESHOLD  = 5    // 【抗噪核心】一行/列必须超过 5 个白点才算数！
)(
    input  wire        clk,
    input  wire        rst_n,

    // 接收形态学闭运算输出的二值化视频流
    input  wire        vs_in,
    input  wire        de_in,
    input  wire [7:0]  bin_data,

    // 提取出的车牌边界框坐标 (供 CPU 读取)
    output reg  [11:0] out_x_min,
    output reg  [11:0] out_x_max,
    output reg  [11:0] out_y_min,
    output reg  [11:0] out_y_max,
    output reg         box_valid  // 坐标计算完成的脉冲标志
);

    // --- 0. 消除仿真时的 X 未知态 ---
    integer i;
    initial begin
        for (i=0; i<2048; i=i+1) begin
            x_ram[i] = 0;
            y_ram[i] = 0;
        end
    end

    // --- 1. 视频流坐标同步生成 ---
    reg        de_r;
    reg        vs_r;
    always @(posedge clk) begin
        de_r <= de_in;
        vs_r <= vs_in;
    end
    wire de_fall = de_r & ~de_in;
    wire vs_rise = ~vs_r & vs_in;

    reg [11:0] x_cnt;
    reg [11:0] y_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= 0; y_cnt <= 0;
        end else begin
            if (vs_rise) begin
                x_cnt <= 0; y_cnt <= 0;
            end else if (de_in) begin
                x_cnt <= x_cnt + 1;
            end else if (de_fall) begin
                x_cnt <= 0; y_cnt <= y_cnt + 1;
            end
        end
    end

    // --- 2. 硬件 RAM 分配 (FPGA 最宝贵的 BRAM 资源) ---
    reg [11:0] x_ram [0:2047]; // X 轴投影 RAM (记录每一列有多少白点)
    reg [11:0] y_ram [0:2047]; // Y 轴投影 RAM (记录每一行有多少白点)

    // --- 3. Y 轴投影实时累加 ---
    reg [11:0] row_w_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_w_cnt <= 0;
        end else begin
            if (de_in && bin_data == 8'hFF) begin
                row_w_cnt <= row_w_cnt + 1;
            end else if (de_fall) begin
                y_ram[y_cnt] <= row_w_cnt; // 行结束时瞬间写入内存
                row_w_cnt <= 0;
            end
        end
    end

    // --- 4. 帧间消隐区处理状态机 (X轴累加、扫描极值、内存清理) ---
    reg [2:0]  state;
    reg [11:0] scan_cnt;
    reg [11:0] tmp_x_min, tmp_x_max;
    reg [11:0] tmp_y_min, tmp_y_max;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= 0; scan_cnt <= 0; box_valid <= 0;
        end else begin
            case (state)
                0: begin // 【阶段 0】：画面传输时，实时累加 X_RAM
                    box_valid <= 0;
                    if (de_in && bin_data == 8'hFF) begin
                        x_ram[x_cnt] <= x_ram[x_cnt] + 1;
                    end

                    if (vs_rise) begin // 画面传完，利用垂直消隐区开始扫描
                        state <= 1; scan_cnt <= 0;
                        tmp_y_min <= 12'hFFF; tmp_y_max <= 0;
                        tmp_x_min <= 12'hFFF; tmp_x_max <= 0;
                    end
                end
                1: begin // 【阶段 1】：扫描 Y_RAM 找上下边界
                    if (scan_cnt < IMG_HEIGHT) begin
                        if (y_ram[scan_cnt] >= THRESHOLD) begin // 滤除噪点！
                            if (tmp_y_min == 12'hFFF) tmp_y_min <= scan_cnt;
                            tmp_y_max <= scan_cnt;
                        end
                        scan_cnt <= scan_cnt + 1;
                    end else begin
                        state <= 2; scan_cnt <= 0;
                    end
                end
                2: begin // 【阶段 2】：扫描 X_RAM 找左右边界
                    if (scan_cnt < IMG_WIDTH) begin
                        if (x_ram[scan_cnt] >= THRESHOLD) begin // 滤除噪点！
                            if (tmp_x_min == 12'hFFF) tmp_x_min <= scan_cnt;
                            tmp_x_max <= scan_cnt;
                        end
                        scan_cnt <= scan_cnt + 1;
                    end else begin
                        state <= 3; scan_cnt <= 0;
                        // 扫描完成，输出最终锁定的防抖边界！
                        out_x_min <= tmp_x_min; out_x_max <= tmp_x_max;
                        out_y_min <= tmp_y_min; out_y_max <= tmp_y_max;
                        box_valid <= 1'b1; // 发送完成脉冲给 CPU
                    end
                end
                3: begin // 【阶段 3】：内存清零，为下一帧做准备
                    box_valid <= 0; 
                    if (scan_cnt < IMG_WIDTH) begin
                        x_ram[scan_cnt] <= 0;
                        scan_cnt <= scan_cnt + 1;
                    end else begin
                        state <= 0; // 回到待机状态，等下一帧
                    end
                end
            endcase
        end
    end
endmodule