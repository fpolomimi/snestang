
// 71*14 bitmap
localparam [70:0] LOGO [14] = '{
    71'b00111000000000000000000000000000111111111000000000000000000000000000000,
    71'b11111000000000000000000000000000111111111000000000000000000000000000000,
    71'b11110000000000000000000000000000111111111000000000000000000000000000000,
    71'b11100000000000000000111000001100000111000000000000000000000000000000000,
    71'b11110001111111100011111100011110000111000001111111101111111110011111111,
    71'b01111001111111110111111110111100000111000011111111101111111110011111111,
    71'b00111001111011110111001110111100000111000011110111100111111110111100111,
    71'b00111101110001110111111110011100000111000011100011100111001110111000111,
    71'b00111101110001110111111000001110000111000011100011100111001110111100111,
    71'b11111001110001110111000000001110000111000011111111100111001110011111111,
    71'b11111001110001110011111110111110000111000011111111100111001110001111111,
    71'b11100001110001110001111100011100000111000001111011100111001110000000111,
    71'b00000000000000000000000000000000000000000000000000000000000000011111111,
    71'b00000000000000000000000000000000000000000000000000000000000000011111110
};

// SNES BGR for bright green
localparam [14:0] LOGO_COLOR = 15'b000001010100000;