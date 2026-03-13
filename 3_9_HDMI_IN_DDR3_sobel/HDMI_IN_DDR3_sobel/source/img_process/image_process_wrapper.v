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
    .cb         (),              
    .cr         ()                 
);

// 2. 3x3 矩阵生成模块实例化 [cite: 126, 127]
matrix_3x3 #(
    .IMG_WIDTH  ( IMG_WIDTH  ), // 使用传入的参数！
    .IMG_HEIGHT ( IMG_HEIGHT )
) u_matrix_3x3 (
    .video_clk  ( clk ),
    .rst_n      ( rst_n ),
    .video_vs   ( y_vs ),
    .video_de   ( y_de ),
    .video_data ( y_data ),
    .matrix_de  ( matrix_de ),
    .matrix11   ( matrix11 ), .matrix12   ( matrix12 ), .matrix13   ( matrix13 ),
    .matrix21   ( matrix21 ), .matrix22   ( matrix22 ), .matrix23   ( matrix23 ),
    .matrix31   ( matrix31 ), .matrix32   ( matrix32 ), .matrix33   ( matrix33 )
);

// Sobel 模块处理完输出的内部连线
wire        sobel_vs;
wire        sobel_de;
wire [7:0]  sobel_data;

// 3. Sobel 边缘检测模块实例化 [cite: 132, 133]
sobel #(
    .SOBEL_THRESHOLD ( 64 ) // 保持与官方顶层一致的 64 阈值 
) u_sobel (
    .video_clk  ( clk ),
    .rst_n      ( rst_n ),
    .matrix_de  ( matrix_de ),
    .matrix_vs  ( y_vs ),
    .matrix11   ( matrix11 ), .matrix12   ( matrix12 ), .matrix13   ( matrix13 ),
    .matrix21   ( matrix21 ), .matrix22   ( matrix22 ), .matrix23   ( matrix23 ),
    .matrix31   ( matrix31 ), .matrix32   ( matrix32 ), .matrix33   ( matrix33 ),
    .sobel_vs   ( sobel_vs ),
    .sobel_de   ( sobel_de ),
    .sobel_data ( sobel_data )
);

// ... 前面是你原有的 RGB2YCbCr, u_matrix_3x3, u_sobel ...
// =========================================================================
// 4. 第二个 3x3 矩阵 (吞入 Sobel 的黑白边缘，生成窗口)
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
    .video_vs   ( sobel_vs ),    
    .video_de   ( sobel_de ),    
    .video_data ( sobel_data ),  // 输入: Sobel 边缘
    
    .matrix_de  ( matrix2_de ),
    .matrix11(m2_11), .matrix12(m2_12), .matrix13(m2_13),
    .matrix21(m2_21), .matrix22(m2_22), .matrix23(m2_23),
    .matrix31(m2_31), .matrix32(m2_32), .matrix33(m2_33)
);

// =========================================================================
// 5. 第一级形态学：膨胀操作 (Dilation)
// =========================================================================
wire        morph1_vs;
wire        morph1_de;
wire [7:0]  morph1_dilate; // 我们只需要它的膨胀结果

morphology u_morphology_dilate (
    .clk         ( clk ),
    .rst_n       ( rst_n ),
    .matrix_vs   ( sobel_vs ),   
    .matrix_de   ( matrix2_de ),
    .p11(m2_11), .p12(m2_12), .p13(m2_13),
    .p21(m2_21), .p22(m2_22), .p23(m2_23),
    .p31(m2_31), .p32(m2_32), .p33(m2_33),
    
    .out_vs      ( morph1_vs ),
    .out_de      ( morph1_de ),
    .dilate_data ( morph1_dilate ), // 提取变胖的图像
    .erode_data  ( /* 悬空不接 */ ) 
);

// =========================================================================
// 6. 第三个 3x3 矩阵 (吞入“膨胀”后的图像，生成新窗口)
// =========================================================================
wire        matrix3_de;
wire [7:0]  m3_11, m3_12, m3_13;
wire [7:0]  m3_21, m3_22, m3_23;
wire [7:0]  m3_31, m3_32, m3_33;

matrix_3x3 #(
    .IMG_WIDTH  ( IMG_WIDTH  ), 
    .IMG_HEIGHT ( IMG_HEIGHT )
) u_matrix_3x3_inst3 (
    .video_clk  ( clk ),
    .rst_n      ( rst_n ),
    .video_vs   ( morph1_vs ),    // 传入第一级形态学的时序
    .video_de   ( morph1_de ),    
    .video_data ( morph1_dilate), // 【关键】输入变成膨胀后的图像！
    
    .matrix_de  ( matrix3_de ),
    .matrix11(m3_11), .matrix12(m3_12), .matrix13(m3_13),
    .matrix21(m3_21), .matrix22(m3_22), .matrix23(m3_23),
    .matrix31(m3_31), .matrix32(m3_32), .matrix33(m3_33)
);

// =========================================================================
// 7. 第二级形态学：腐蚀操作 (Erosion)
// =========================================================================
wire [7:0]  morph2_erode;

morphology u_morphology_erode (
    .clk         ( clk ),
    .rst_n       ( rst_n ),
    .matrix_vs   ( morph1_vs ),   
    .matrix_de   ( matrix3_de ),
    .p11(m3_11), .p12(m3_12), .p13(m3_13),
    .p21(m3_21), .p22(m3_22), .p23(m3_23),
    .p31(m3_31), .p32(m3_32), .p33(m3_33),
    
    // 最终输出给 Testbench
    .out_vs      ( post_vs ),
    .out_de      ( post_de ),
    .dilate_data ( /* 悬空不接 */ ), 
    .erode_data  ( morph2_erode )  // 提取变瘦的图像
);

// =========================================================================
// 【终极输出选择】: 闭运算 = 先膨胀，再腐蚀
// =========================================================================
assign post_data = morph2_erode;

endmodule