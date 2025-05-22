
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;


entity sid_voice_tb is
generic (
  CLK_CYCLE_TIME  : time     := 100 ns;
  CLK_HIGH_TIME   : time     := 50 ns;
  DATA_SETUP_TIME : time     := 4 ns;
  DATA_HOLD_TIME  : time     := 4 ns
  );
end entity;



architecture testbench of sid_voice_tb is

  component sid_clock
  port (    
	sysclk	: in  std_logic;
    sid_clk : out std_logic;
	quanta	: out integer range 0 to 120  -- must be equal to MAX_QUANTA
  );
  end component;

  component sid_voice
  port(
	clk_1MHz		: in	std_logic;						-- this line drives the oscilator
	reset			: in	std_logic;						-- active high signal (i.e. registers are reset when reset=1)
	Freq_lo			: in	std_logic_vector(7 downto 0);	-- low-byte of frequency register 
	Freq_hi			: in	std_logic_vector(7 downto 0);	-- high-byte of frequency register 
	Pw_lo			: in	std_logic_vector(7 downto 0);	-- low-byte of PuleWidth register
	Pw_hi			: in	std_logic_vector(3 downto 0);	-- high-nibble of PuleWidth register
	Control			: in	std_logic_vector(7 downto 0);	-- control register
	Att_dec			: in	std_logic_vector(7 downto 0);	-- attack-deccay register
	Sus_Rel			: in	std_logic_vector(7 downto 0);	-- sustain-release register
	PA_MSB_in		: in	std_logic;						-- Phase Accumulator MSB input
	PA_MSB_out	    : out	std_logic;						-- Phase Accumulator MSB output
	Osc				: out	std_logic_vector(7 downto 0);	-- Voice waveform register
	Env				: out	std_logic_vector(7 downto 0);	-- Voice envelope register
	voice			: out	std_logic_vector(11 downto 0)	-- Voice waveform, this is the actual audio signal
  );
  end component;
  
	-- CLOCK and RESET signals
  signal clock:    std_logic;
  signal ticks:    integer range 0 to 127;
  signal sid_clk	: std_logic;
  signal reset		: std_logic;
  signal clk50, clk25 : std_logic := '0'; -- 50 and 25 MHz aux clocks  
  signal cycle_number : integer;

	-- signals required by SID VOICE component
  signal frequency 	: std_logic_vector(15 downto 0); 		-- frequency value to output
  signal duty 		: std_logic_vector(11 downto 0); 		-- duty for pulse waveform
  signal control 	: std_logic_vector(7 downto 0); 		-- control register
  signal attack		: std_logic_vector(3 downto 0);			-- attack rate
  signal decay		: std_logic_vector(3 downto 0);			-- decay rate
  signal sustain	: std_logic_vector(3 downto 0);			-- sustain level
  signal releas		: std_logic_vector(3 downto 0);			-- release rate
  signal msb_prev, 
		msb_out 	: std_logic;							-- MSB input from prev voice, MSB output to next Voice
  signal osc_value	: std_logic_vector(7 downto 0);			-- oscillator value (upper 8b of phase accumulator)
  signal env_value	: std_logic_vector(7 downto 0);			-- envelope generator value
  signal voice_value : std_logic_vector(11 downto 0);		-- audio value
  
	-- alias the Control() bits to symbolic names
  alias	en_noise		: std_logic is control(7);
  alias	en_pulse		: std_logic is control(6);
  alias	en_sawtooth		: std_logic is control(5);
  alias	en_triangle		: std_logic is control(4);
  alias	test			: std_logic is control(3);
  alias	ringmod			: std_logic is control(2);
  alias	sync			: std_logic is control(1);
  alias	gate			: std_logic is control(0);  
  
  constant CLK_PERIOD : time := 100 ns;
   
begin
  
  -- instantiate clock generator
  sid_clock_dut: sid_clock 
  port map(
    sysclk=>clock, 
	sid_clk=>sid_clk, 
	quanta=>ticks
  );
  
  -- instantiate SID voice
  sid_voice_dut: sid_voice 
  port map(
	clk_1MHz=>sid_clk,
	reset=>reset,
	Freq_lo=>frequency(7 downto 0),
	Freq_hi=>frequency(15 downto 8),
	Pw_lo=>duty(7 downto 0),
	Pw_hi=>duty(11 downto 8),
	Control=>control(7 downto 0),
	Att_dec=>attack(3 downto 0) & decay(3 downto 0),
	Sus_Rel=>sustain(3 downto 0) & releas(3 downto 0),
	PA_MSB_in=>msb_prev,
	PA_MSB_out=>msb_out,
	Osc=>osc_value,
	Env=>env_value,
	voice=>voice_value
  );
   
  -- generate system clock
  process 
  begin
    clock <= '0';
	wait for CLK_PERIOD/2;
	clock <= '1';
	wait for CLK_PERIOD/2;
  end process;
  
  -- power-on-reset process
  process
  begin
    reset <= '1', '0' after CLK_PERIOD*5;
    wait;	
  end process;
  
  -- generate 50 MHz and 25 MHz aux clocks
  process (clock)
  begin
    if rising_edge(clock) then
	  clk50 <= not clk50;
	  if (clk50 = '1') then
	    clk25 <= not clk25;
	  end if;
	end if;
  end process;

  -- count SID clock cycles
  process
	file output_file : text open write_mode is "output.csv";
	variable line_data : line;  
	variable header : integer := 0;
  begin
	-- synchronize to SID clock
    wait until falling_edge(sid_clk);
	if (reset = '1') then
	  cycle_number <= 0;
	  
	-- only write 1000001 samples to output file (100ms)
	elsif (cycle_number < 100001) then
	  write(line_data, integer'image(to_integer(signed(voice_value))));
	  writeline(output_file, line_data);	
      cycle_number <= cycle_number + 1;
	end if;
  end process;
  
  -- setup and exercise SID voice 
  process
  begin
	  frequency <= "0011110011010110";
	  duty <= "100000000000"; 
	  attack <= "0000";
	  decay <= "0000";
	  sustain <= "0000";
	  releas <= "0000";
	  msb_prev <= '0';
	  en_noise <= '0';
	  en_pulse <= '0';
	  en_sawtooth <= '0';
	  en_triangle <= '0';
	  test <= '0';
	  ringmod <= '0';
	  sync <= '0';
	  gate <= '0';
    wait until falling_edge(reset);
	
	wait until falling_edge(sid_clk);
	en_triangle <= '1';

	wait until falling_edge(sid_clk);
	  duty <= "100000000000"; 
	  attack <= "0011";
	  decay <= "0001";
	  sustain <= "1000";
	  releas <= "0011";
      gate <= '1';
	
	wait for 60 ms;	
      gate <= '0';
	  duty <= "010000000000"; 	
	
	wait;
  end process;

end;




