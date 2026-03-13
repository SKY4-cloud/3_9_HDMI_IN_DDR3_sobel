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

// 3. Sobel 边缘检测模块实例化 [cite: 132, 133]
sobel #(
    .SOBEL_THRESHOLD ( 64 ) // 保持与官方顶层一致的 64 阈值 
) u_post (
    .video_clk  ( clk ),
    .rst_n      ( rst_n ),
    .matrix_de  ( matrix_de ),
    .matrix_vs  ( y_vs ),
    .matrix11   ( matrix11 ), .matrix12   ( matrix12 ), .matrix13   ( matrix13 ),
    .matrix21   ( matrix21 ), .matrix22   ( matrix22 ), .matrix23   ( matrix23 ),
    .matrix31   ( matrix31 ), .matrix32   ( matrix32 ), .matrix33   ( matrix33 ),
    .post_vs   ( post_vs ),
    .post_de   ( post_de ),
    .post_data ( post_data )
);

// ... 前面是你原有的 RGB2YCbCr, u_matrix_3x3, u_sobel ...
// 注意：下面这段代码要插在 endmodule 之前！

// 定义第二级流水线的连线
wire        matrix2_de;
wire [7:0]  m2_11, m2_12, m2_13;
wire [7:0]  m2_21, m2_22, m2_23;
wire [7:0]  m2_31, m2_32, m2_33;

wire [7:0]  dilate_res;
wire [7:0]  erode_res;

// 4. 第二个 3x3 矩阵 (吞入 Sobel 的输出，生成新的 3x3 窗口)
matrix_3x3 #(
    .IMG_WIDTH  ( IMG_WIDTH  ), 
    .IMG_HEIGHT ( IMG_HEIGHT )
) u_matrix_3x3_inst2 (
    .video_clk  ( clk ),
    .rst_n      ( rst_n ),
    .video_vs   ( sobel_vs ),    // 把 sobel 的 vsync 传过来
    .video_de   ( sobel_de ),    // 把 sobel 的 de 传过来
    .video_data ( sobel_data ),  // 【关键】输入变成 Sobel 的黑白边缘图！
    
    .matrix_de  ( matrix2_de ),
    .matrix11(m2_11), .matrix12(m2_12), .matrix13(m2_13),
    .matrix21(m2_21), .matrix22(m2_22), .matrix23(m2_23),
    .matrix31(m2_31), .matrix32(m2_32), .matrix33(m2_33)
);

// 5. 形态学运算模块
morphology u_morphology (
    .clk         ( clk ),
    .rst_n       ( rst_n ),
    .matrix_vs   ( sobel_vs ),   
    .matrix_de   ( matrix2_de ),
    .p11(m2_11), .p12(m2_12), .p13(m2_13),
    .p21(m2_21), .p22(m2_22), .p23(m2_23),
    .p31(m2_31), .p32(m2_32), .p33(m2_33),
    
    .out_vs      ( post_vs ),  // 最终输出给 Testbench
    .out_de      ( post_de ),
    .dilate_data ( dilate_res ),
    .erode_data  ( erode_res )
);

// 【终极输出选择】
// 架构师建议：对于车牌，膨胀的效果最明显，我们先输出膨胀结果看看！
assign post_data = dilate_res;  // 如果你想看腐蚀，就改成 erode_res


endmodule