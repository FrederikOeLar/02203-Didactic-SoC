--------------------------------------------------------------
-- Performes the calculations of the pixels
-- This pixel calculator expects top right pixel to be
-- pixels(0) and top left pixel to be pixels(2)
--
-- Only bits 7..0 of each pixels(i) entry are used (8-bit pixel).
-- Dx and Dy lie in [-1020, 1020], so they are computed in 11 bits
-- (two's complement). |Dx| + |Dy| is at most 2040, so dividing
-- by 8 maps the result onto 0..255 without saturation.
--------------------------------------------------------------


library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.types.all;

entity pix_calc is 
    port (
        pixels      : in    word_array_t; 
        pix_result  : out   std_logic_vector(7 downto 0)
    ); 
end pix_calc; 

architecture rtl of pix_calc is
    signal dx : std_logic_vector(10 downto 0);
    signal dy : std_logic_vector(10 downto 0);

    signal abs_dx : std_logic_vector(10 downto 0);
    signal abs_dy : std_logic_vector(10 downto 0);

    signal sum    : unsigned(10 downto 0);

    -- 8-bit pixel zero-extended to 11 bits
    function px(p : std_logic_vector(31 downto 0)) return unsigned is
    begin
        return resize(unsigned(p(7 downto 0)), 11);
    end function;
begin

    -- Unsigned arithmetic wraps modulo 2^11, which gives the correct
    -- two's complement result because the true value fits in 11 bits.
    dx <= std_logic_vector(
        px(pixels(0)) - px(pixels(2)) +
        shift_left(px(pixels(3)) - px(pixels(5)), 1) +
        px(pixels(6)) - px(pixels(8)));

    dy <= std_logic_vector(
        px(pixels(2)) - px(pixels(8)) +
        shift_left(px(pixels(1)) - px(pixels(7)), 1) +
        px(pixels(0)) - px(pixels(6)));

    process(all)
    begin
        if (dx(10) = '1') then
            abs_dx <= std_logic_vector(unsigned(not dx) + 1);
        else
            abs_dx <= dx;
        end if;

        if (dy(10) = '1') then
            abs_dy <= std_logic_vector(unsigned(not dy) + 1);
        else
            abs_dy <= dy;
        end if;
    end process;

    sum <= unsigned(abs_dx) + unsigned(abs_dy);   -- max 2040

    pix_result <= std_logic_vector(sum(10 downto 3)); -- divide by 8

end rtl; 