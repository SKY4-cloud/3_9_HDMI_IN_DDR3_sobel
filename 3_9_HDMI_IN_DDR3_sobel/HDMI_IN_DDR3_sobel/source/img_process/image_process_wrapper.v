`timescale 1ns / 1ps

module image_process_wrapper #(
    parameter IMG_WIDTH  = 200, // 仿真时会被 Testbench 覆盖
    parameter IMG_HEIGHT = 100
)(
    input  wire        clk,
    input  wire        rst_n,
    
    // 从虚拟摄像头输入的信号
    input  wire        vs_in,
    input  wire        de_in,
    input  wire [7:0]  r_in,
    input  wire [7:0]  g_in,
    input  wire [7:0]  b_in,

    // 算法处理完输出的信号
    output wire        post_vs,
    output wire        post_de,
    output wire [7:0]  post_data
);

// 内部连接线 [cite: 117, 121, 129]
wire        y_vs;
wire        y_hs;
wire        y_de;
wire [7:0]  y_data;
wire [7:0]  cb_data; // 【新增】：接出蓝色色度通道

wire        matrix_de;
wire [7:0]  matrix11, matrix12, matrix13;
wire [7:0]  matrix21, matrix22, matrix23;
wire [7:0]  matrix31, matrix32, matrix33;

// 1. 灰度化模块实例化 (完全参照官方连线) [cite: 118, 119]
RGB2YCbCr RGB2YCbCr_inst (
    .clk        (clk),              
    .rst_n      (rst_n),          
    .vsync_in   (vs_in),    
    .hsync_in   (de_in),  // 官方代码这里将 de 接给了 hsync   
    .de_in      (de_in),          
    .red        (r_in[7:3]),  // 取高位，RGB888 转 RGB565             
    .green      (g_in[7:2]),          
    .blue       (b_in[7:3]),            
    .vsync_out  (y_vs),  
    .hsync_out  (y_hs),  
    .de_out     (y_de),        
    .y          (y_data),                  
    .cb      ( cb_data ),              
    .cr         ()                 
);

// =========================================================================
// 【全新加入】2. Cb 色彩通道二值化 (彻底替代 Sobel)
// =========================================================================
reg         cb_bin_vs;
reg         cb_bin_de;
reg  [7:0]  cb_bin_data;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cb_bin_vs   <= 0;
        cb_bin_de   <= 0;
        cb_bin_data <= 8'd0;
    end else begin
        cb_bin_vs   <= y_vs; // 时序直接借用 Y 通道的，完美对齐
        cb_bin_de   <= y_de;
        
        // 阈值判断：国内蓝牌的 Cb 值通常极高（130~170）
        // 如果大于 130，说明是蓝色车牌底色，变成纯白；否则变纯黑。
        if (cb_data > 8'd130)
            cb_bin_data <= 8'd255; 
        else
            cb_bin_data <= 8'd0;   
    end
end

// =========================================================================
// 3. 矩阵 1：为膨胀生成 3x3 窗口
// =========================================================================
wire        matrix1_de;
wire [7:0]  m1_11, m1_12, m1_13;
wire [7:0]  m1_21, m1_22, m1_23;
wire [7:0]  m1_31, m1_32, m1_33;

matrix_3x3 #(
    .IMG_WIDTH  ( IMG_WIDTH  ), 
    .IMG_HEIGHT ( IMG_HEIGHT )
) u_matrix_3x3_inst1 (
    .video_clk  ( clk ),
    .rst_n      ( rst_n ),
    .video_vs   ( cb_bin_vs ),    
    .video_de   ( cb_bin_de ),    
    .video_data ( cb_bin_data ),  // <--- 输入二值化后的蓝色区域！
    
    .matrix_de  ( matrix1_de ),
    .matrix11(m1_11), .matrix12(m1_12), .matrix13(m1_13),
    .matrix21(m1_21), .matrix22(m1_22), .matrix23(m1_23),
    .matrix31(m1_31), .matrix32(m1_32), .matrix33(m1_33)
);

// =========================================================================
// 4. 形态学 1：膨胀 
// 【架构师原理解密】车牌底色是蓝的(变白)，字是白的(变黑)。
// 所以现在的车牌是一个白底黑字的“窟窿图”。用膨胀(OR)可以直接把黑字窟窿全填满！
// =========================================================================
wire        morph1_vs;
wire        morph1_de;
wire [7:0]  morph1_dilate;

morphology u_morphology_dilate (
    .clk         ( clk ),
    .rst_n       ( rst_n ),
    .matrix_vs   ( cb_bin_vs ),   
    .matrix_de   ( matrix1_de ),
    .p11(m1_11), .p12(m1_12), .p13(m1_13),
    .p21(m1_21), .p22(m1_22), .p23(m1_23),
    .p31(m1_31), .p32(m1_32), .p33(m1_33),
    
    .out_vs      ( morph1_vs ),
    .out_de      ( morph1_de ),
    .dilate_data ( morph1_dilate ), 
    .erode_data  (  ) // 悬空不接
);

// =========================================================================
// 5. 矩阵 2：为腐蚀生成 3x3 窗口
// =========================================================================
wire        matrix2_de;
wire [7:0]  m2_11, m2_12, m2_13;
wire [7:0]  m2_21, m2_22, m2_23;
wire [7:0]  m2_31, m2_32, m2_33;

matrix_3x3 #(
    .IMG_WIDTH  ( IMG_WIDTH  ), 
    .IMG_HEIGHT ( IMG_HEIGHT )
) u_matrix_3x3_inst2 (
    .video_clk  ( clk ),
    .rst_n      ( rst_n ),
    .video_vs   ( morph1_vs ),    
    .video_de   ( morph1_de ),    
    .video_data ( morph1_dilate), // 吞入变胖的、填满字体的图像
    
    .matrix_de  ( matrix2_de ),
    .matrix11(m2_11), .matrix12(m2_12), .matrix13(m2_13),
    .matrix21(m2_21), .matrix22(m2_22), .matrix23(m2_23),
    .matrix31(m2_31), .matrix32(m2_32), .matrix33(m2_33)
);

// =========================================================================
// 6. 形态学 2：腐蚀 
// 【目的】消除背景里可能出现的蓝色小斑点干扰，并且把车牌边框削回原尺寸。
// =========================================================================
wire [7:0]  morph2_erode;

morphology u_morphology_erode (
    .clk         ( clk ),
    .rst_n       ( rst_n ),
    .matrix_vs   ( morph1_vs ),   
    .matrix_de   ( matrix2_de ),
    .p11(m2_11), .p12(m2_12), .p13(m2_13),
    .p21(m2_21), .p22(m2_22), .p23(m2_23),
    .p31(m2_31), .p32(m2_32), .p33(m2_33),
    
    .out_vs      ( post_vs ),
    .out_de      ( post_de ),
    .dilate_data ( ), 
    .erode_data  ( morph2_erode ) 
);

// 终极输出闭运算结果
assign post_data = morph2_erode;
// =========================================================================
// 【最终大招】7. 硬件直方图投影 (边界提取器)
// =========================================================================
wire [11:0] box_x_min, box_x_max, box_y_min, box_y_max;
wire        box_valid;

projection_extractor #(
    .IMG_WIDTH  ( IMG_WIDTH  ),
    .IMG_HEIGHT ( IMG_HEIGHT ),
    .THRESHOLD  ( 5 ) // 抗噪阈值：低于 5 个像素的噪点直接无视
) u_projection (
    .clk        ( clk ),
    .rst_n      ( rst_n ),
    .vs_in      ( post_vs ),  // 形态学输出的时序
    .de_in      ( post_de ),
    .bin_data   ( post_data ),// 形态学输出的大白块图

    .out_x_min  ( box_x_min ),
    .out_x_max  ( box_x_max ),
    .out_y_min  ( box_y_min ),
    .out_y_max  ( box_y_max ),
    .box_valid  ( box_valid )
);

// [魔法展示] 仅用于仿真测试：当坐标算出来时，在控制台打印出来！
// synthesis translate_off
always @(posedge clk) begin
    if (box_valid) begin
        $display("\n========================================");
        $display(" [硬件投影加速器] 车牌坐标锁定成功！");
        $display(" X 轴边界: %0d -> %0d", box_x_min, box_x_max);
        $display(" Y 轴边界: %0d -> %0d", box_y_min, box_y_max);
        $display("========================================\n");
    end
end
// synthesis translate_on
endmodule