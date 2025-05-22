library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- SID core clock generation
----------------------------
--
-- The target SID core frequency is 1 MHz, and the assumed input clock frequency
-- is 100 MHz. One core cycle is 100 'ticks'.
--
-- For simulation, make the input clock 5 MHz instead!
--


entity sid_clock is 
  generic (
	SID_QUANTA : integer := 10
  );
  port (    
	sysclk	: in  std_logic;
    sid_clk : out std_logic;
	quanta	: out integer range 0 to 120  -- must be equal to MAX_QUANTA
  );
end sid_clock;

architecture simulation of sid_clock is
	signal clock_state : integer range 0 to 120;
	signal sid_drive : std_logic;
	
begin
	clock_advance : process(sysclk) begin
	   if rising_edge(sysclk) then
		  if (clock_state >= SID_QUANTA) then
		  	 clock_state <= 0;
		  else 
		     clock_state <= clock_state + 1;
	   	  end if;
	   end if;
	end process;
	
	-- generate the SID clock drive signal
	sid_drive <= '1' when (clock_state < SID_QUANTA/2) else '0';
	sid_clk <= sid_drive;
	
	-- output the 'tick' value
	quanta <= clock_state;

end simulation;

