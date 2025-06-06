-------------------------------------------------------------------------------
--
--                                 SID 6581 (voice)
--
--     This piece of VHDL code describes a single SID voice (sound channel)
--
-------------------------------------------------------------------------------
--	Voice output is scaled to 12bits
-------------------------------------------------------------------------------

library IEEE;
use IEEE.std_logic_1164.all;
--use IEEE.std_logic_arith.all;
use IEEE.std_logic_unsigned.all;
use IEEE.numeric_std.all;

-------------------------------------------------------------------------------

entity sid_voice is
	port (
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
end sid_voice;

architecture Behavioral of sid_voice is	

-------------------------------------------------------------------------------

signal	accumulator						: std_logic_vector(23 downto 0) := (others => '0');
signal	accu_bit_prev					: std_logic := '0';
signal	PA_MSB_in_prev				    : std_logic := '0';

-- this type of signal has only two states 0 or 1 (so no more bits are required)
signal	pulse							: std_logic_vector(11 downto 0) := (others => '0');
signal	sawtooth						: std_logic_vector(11 downto 0) := (others => '0');
signal	triangle						: std_logic_vector(11 downto 0) := (others => '0');
signal	noise							: std_logic_vector(11 downto 0) := (others => '0');
signal	LFSR							: std_logic_vector(22 downto 0) := (others => '0');
signal 	frequency						: std_logic_vector(15 downto 0) := (others => '0');
signal 	pulsewidth						: std_logic_vector(11 downto 0) := (others => '0');

-- Envelope Generator
type	envelope_state_types is 	(idle, attack, attack_lp, decay, decay_lp, sustain, releas, release_lp);
signal 	cur_state, next_state	        : envelope_state_types; 
signal 	divider_value					: integer range 0 to 2**15 - 1 :=0;
signal 	divider_attack				    : integer range 0 to 2**15 - 1 :=0;
signal 	divider_dec_rel		    		: integer range 0 to 2**15 - 1 :=0;
signal 	divider_counter		    		: integer range 0 to 2**18 - 1 :=0;
signal 	exp_table_value		    		: integer range 0 to 2**18 - 1 :=0;
signal 	exp_table_active	    		: std_logic := '0';
signal 	divider_rst 					: std_logic := '0';
signal	Dec_rel							: std_logic_vector(3 downto 0) := (others => '0');
signal	Dec_rel_sel						: std_logic := '0';

signal	env_counter						: std_logic_vector(7 downto 0) := (others => '0');
signal 	env_count_hold_A		    	: std_logic := '0';
signal	env_count_hold_B			    : std_logic := '0';
signal	env_cnt_up						: std_logic := '0';
signal	env_cnt_clear					: std_logic := '0';

signal	signal_mux						: std_logic_vector(11 downto 0) := (others => '0');
signal	signal_vol						: std_logic_vector(signal_mux'high+env_counter'high+2 downto 0) := (others => '0');

-------------------------------------------------------------------------------------

-- Enable noise
alias		en_noise								: std_logic is Control(7);
-- Enable pulse
alias		en_pulse								: std_logic is Control(6);
-- Enable sawtooth
alias		en_sawtooth								: std_logic is Control(5);
-- Enable triangle
alias		en_triangle								: std_logic is Control(4);
-- stop the oscillator when test = '1'
alias		test									: std_logic is Control(3);
-- Ring Modulation was accomplished by substituting the accumulator MSB of an
-- oscillator in the EXOR function of the triangle waveform generator with the
-- accumulator MSB of the previous oscillator. That is why the triangle waveform
-- must be selected to use Ring Modulation.
alias		ringmod								    : std_logic is Control(2);
-- Hard Sync was accomplished by clearing the accumulator of an Oscillator
-- based on the accumulator MSB of the previous oscillator.
alias		sync									: std_logic is Control(1);
--
alias		gate									: std_logic is Control(0);

-------------------------------------------------------------------------------------

begin

-- output the Phase accumulator's MSB for sync and ringmod purposes
PA_MSB_out	            <= accumulator(23);
-- output the upper 8-bits of the waveform.
-- Useful for random numbers (noise must be selected)
Osc			            <= signal_mux(11 downto 4);
-- output the envelope register, for special sound effects when connecting this
-- signal to the input of other channels/voices
Env			            <= env_counter;
-- use the register value to fill the variable
frequency               <= Freq_hi & Freq_lo;
-- use the register value to fill the variable
pulsewidth          	<= Pw_hi & Pw_lo;
--
voice					<= signal_vol(signal_vol'high-1 downto signal_vol'high-12);

-- Phase accumulator :
-- "As I recall, the Oscillator is a 24-bit phase-accumulating design of which
-- the lower 16-bits are programmable for pitch control. The output of the
-- accumulator goes directly to a D/A converter through a waveform selector.
-- Normally, the output of a phase-accumulating oscillator would be used as an
-- address into memory which contained a wavetable, but SID had to be entirely
-- self-contained and there was no room at all for a wavetable on the chip."
-- "Hard Sync was accomplished by clearing the accumulator of an Oscillator
-- based on the accumulator MSB of the previous oscillator."
-- PAL:  x = f * (18*2^24)/17734475   (0 - 3848 Hz)
-- NTSC: x = f * (14*2^24)/14318182   (0 - 3995 Hz)
PhaseAcc:process(clk_1MHz)
begin
	if rising_edge(clk_1MHz) then
		PA_MSB_in_prev <= PA_MSB_in;
		-- the reset and test signal can stop the oscillator,
		-- stopping the oscillator is very useful when you want to play "samples"
		if ((reset = '1') or (test = '1') or ((sync = '1') and (PA_MSB_in_prev /= PA_MSB_in) and (PA_MSB_in = '0'))) then
			accumulator <= (others => '0');
		else
			-- accumulate the new phase (i.o.w. increment env_counter with the freq. value)
			accumulator <= accumulator + ("0" & frequency(15 downto 0));
		end if;
	end if;
end process;

-- Sawtooth waveform :
-- "The Sawtooth waveform was created by sending the upper 12-bits of the
-- accumulator to the 12-bit Waveform D/A."
sawtooth <= accumulator(23 downto 12);

--Pulse waveform :
-- "The Pulse waveform was created by sending the upper 12-bits of the
-- accumulator to a 12-bit digital comparator. The output of the comparator was
-- either a one or a zero. This single output was then sent to all 12 bits of
-- the Waveform D/A. "
pulse <= (others => '0') when accumulator(23 downto 12) < pulsewidth else (others => '1');

--Triangle waveform :
-- "The Triangle waveform was created by using the MSB of the accumulator to
-- invert the remaining upper 11 accumulator bits using EXOR gates. These 11
-- bits were then left-shifted (throwing away the MSB) and sent to the Waveform
-- D/A (so the resolution of the triangle waveform was half that of the sawtooth,
-- but the amplitude and frequency were the same). "
-- "Ring Modulation was accomplished by substituting the accumulator MSB of an
-- oscillator in the EXOR function of the triangle waveform generator with the
-- accumulator MSB of the previous oscillator. That is why the triangle waveform
-- must be selected to use Ring Modulation."
triangle <= (11 downto 0 => accumulator(23)) xor accumulator(22 downto 11) when ringmod = '0' else
            (11 downto 0 => PA_MSB_in)       xor accumulator(22 downto 11);

--Noise (23-bit Linear Feedback Shift Register, max combinations = 8388607) :
-- "The Noise waveform was created using a 23-bit pseudo-random sequence
-- generator (i.e., a shift register with specific outputs feed back to the input
-- through combinatorial logic). The shift register was clocked by one of the
-- intermediate bits of the accumulator to keep the frequency content of the
-- noise waveform relatively the same as the pitched waveforms.
-- The upper 12-bits of the shift register were sent to the Waveform D/A."
--noise <= LFSR(22 downto 11) when en_noise = '1' else (others => '0');

-- Proper noise output is taken from bits 22,20,16,13,11,7,4,2 for the 8bit register (OSC3)//Walter
-- Sound wise it might not matter much but some games might rely on the exact sequence as well as the start value!
noise <= LFSR(22) & LFSR(20) & LFSR(16) & LFSR(13) & LFSR(11) & LFSR(7) & LFSR(4) & LFSR(2) & LFSR(19) & LFSR(17) & LFSR(9) & LFSR(3);

Snd_noise:process(clk_1MHz)
begin
	if rising_edge(clk_1MHz) then
		-- the test signal can stop the oscillator,
		-- stopping the oscillator is very useful when you want to play "samples"
		if ((reset = '1') or (test = '1')) then
			accu_bit_prev <= '0';
			-- the "seed" value (the value that eventually determines the output
			-- pattern) may never be '0' otherwise the generator "locks up"
			LFSR	<= b"0000_0000_0000_0000_0000_001";
            -- LFSR <= b"1111_1111_1111_1111_1111_000";    --A long reset will eventually result in this start value //Walter
		else
			accu_bit_prev <= accumulator(22);
			-- when not equal to ...
			if	(accu_bit_prev /= accumulator(22)) then
				LFSR(22 downto 0) <= LFSR(21 downto 0) & std_logic(LFSR(22) xor LFSR(17));
			end if;
		end if;
	end if;
end process;

-- Waveform Output selector (MUX):
-- "Since all of the waveforms were just digital bits, the Waveform Selector
-- consisted of multiplexers that selected which waveform bits would be sent
-- to the Waveform D/A. The multiplexers were single transistors and did not
-- provide a "lock-out", allowing combinations of the waveforms to be selected.
-- The combination was actually a logical ANDing of the bits of each waveform,
-- which produced unpredictable results, so I didn't encourage this, especially
-- since it could lock up the pseudo-random sequence generator by filling it
-- with zeroes."
-- Added approximations of mixed waveforms //Walter
Snd_select:process(clk_1MHz)
begin
	if rising_edge(clk_1MHz) then
		case Control(7 downto 4) is
            when x"0" => signal_mux <= (others => '0');
            when x"1" => signal_mux <= triangle;
            when x"2" => signal_mux <= sawtooth;
            when x"3" => signal_mux <= (sawtooth(sawtooth'high-1 downto 0) AND (sawtooth(sawtooth'high-2 downto 0) & "0") AND (sawtooth(sawtooth'high downto 1))) & "0";
            when x"4" => signal_mux <= pulse;
            when x"5" => signal_mux <= triangle AND (triangle(triangle'high-1 downto 0) & "0");
            when x"6" => signal_mux <= sawtooth AND (sawtooth(sawtooth'high-1 downto 0) & "0");
            when x"7" => signal_mux <= (sawtooth(sawtooth'high-1 downto 0) AND (sawtooth(sawtooth'high-2 downto 0) & "0") AND (sawtooth(sawtooth'high downto 1))) & "0";
            when x"8" => signal_mux <= noise;
            when others => signal_mux <= (others => '0');
        end case;
	end if;
end process;

-- Waveform envelope (volume) control :
-- "The output of the Waveform D/A (which was an analog voltage at this point)
-- was fed into the reference input of an 8-bit multiplying D/A, creating a DCA
-- (digitally-controlled-amplifier). The digital control word which modulated
-- the amplitude of the waveform came from the Envelope Generator."
-- "The 8-bit output of the Envelope Generator was then sent to the Multiplying
-- D/A converter to modulate the amplitude of the selected Oscillator Waveform
-- (to be technically accurate, actually the waveform was modulating the output
-- of the Envelope Generator, but the result is the same)."
Envelope_multiplier:process(clk_1MHz)
begin
	if rising_edge(clk_1MHz) then
			 --calculate the resulting volume (due to the envelope generator) of the
			 --voice, signal_mux(12bit) * env_counter(8bit), so the result will
			 --require 20 bits !!
		signal_vol	<= std_logic_vector(signed((NOT signal_mux(signal_mux'high) & signal_mux(signal_mux'high-1 downto 0))) * signed("0" & env_counter));    --Two's complement
	end if;
end process;

-- Envelope generator :
-- "The Envelope Generator was simply an 8-bit up/down counter which, when
-- triggered by the Gate bit, counted from 0 to 255 at the Attack rate, from
-- 255 down to the programmed Sustain value at the Decay rate, remained at the
-- Sustain value until the Gate bit was cleared then counted down from the
-- Sustain value to 0 at the Release rate."
--
--		      /\
--		     /  \ 
--		    / |  \________
--		   /  |   |       \
--		  /   |   |       |\
--		 /    |   |       | \
--		attack|dec|sustain|rel

-- this process controls the state machine "current-state"-value
Envelope_SM_advance: process (reset, clk_1MHz)
begin
	if (reset = '1') then
		cur_state <= idle;
	elsif rising_edge(clk_1MHz) then
		cur_state <= next_state;
	end if;
end process;


-- this process controls the envelope (in other words, the volume control)
Envelope_SM: process (reset, cur_state, gate, divider_attack, divider_dec_rel, Sus_Rel, env_counter)
begin
	if (reset = '1') then
		next_state 				<= idle;
		env_cnt_clear			<='1';
		env_cnt_up				<='1';
		env_count_hold_B	    <='1';
		divider_rst 			<='1';
		divider_value 		    <= 0;
		exp_table_active 	    <='0';
		Dec_rel_sel				<='0';		-- select decay as input for decay/release table
	else
		env_cnt_clear	 		<='0';		-- use this statement unless stated otherwise
		env_cnt_up				<='1';		-- use this statement unless stated otherwise
		env_count_hold_B	    <='1';		-- use this statement unless stated otherwise
		divider_rst 			<='0';		-- use this statement unless stated otherwise
		divider_value 	    	<= 0;		-- use this statement unless stated otherwise
		exp_table_active    	<='0';		-- use this statement unless stated otherwise
		case cur_state is

			-- IDLE
			when idle =>
				env_cnt_clear 		    <= '1';		-- clear envelope env_counter
				divider_rst 			<= '1';
				Dec_rel_sel				<= '0';		-- select decay as input for decay/release table
				if gate = '1' then
					next_state			<= attack;
				else
					next_state 			<= idle;
				end if;
			
			when attack =>
				env_cnt_clear			<= '1';			-- clear envelope env_counter
				divider_rst 			<= '1';
				divider_value 		    <= divider_attack;
				next_state 				<= attack_lp;
				Dec_rel_sel				<= '0';			-- select decay as input for decay/release table
			
			when attack_lp =>
				env_count_hold_B 	    <= '0';		-- enable envelope env_counter
				env_cnt_up 				<= '1';		-- envelope env_counter must count up (increment)
				divider_value 		    <= divider_attack;
				Dec_rel_sel				<= '0';		-- select decay as input for decay/release table
				if env_counter = "11111111" then
					next_state			<= decay;
				elsif gate = '0' then
					next_state		    <= releas;
				else
					next_state		    <= attack_lp;
				end if;
		
			when decay =>
				divider_rst 			<= '1';
				exp_table_active 	    <= '1';		-- activate exponential look-up table
				env_cnt_up	 			<= '0';		-- envelope env_counter must count down (decrement)
				divider_value 		    <= divider_dec_rel;
				next_state 				<= decay_lp;
				Dec_rel_sel				<= '0';		-- select decay as input for decay/release table
			
			when decay_lp =>
				exp_table_active 	    <= '1';		-- activate exponential look-up table
				env_count_hold_B    	<= '0';		-- enable envelope env_counter
				env_cnt_up 				<= '0';		-- envelope env_counter must count down (decrement)
				divider_value 		    <= divider_dec_rel;
				Dec_rel_sel				<= '0';		-- select decay as input for decay/release table
				if (env_counter(7 downto 4) = Sus_Rel(7 downto 4)) then
					next_state 			<= sustain;
				elsif gate = '0' then
					next_state		    <= releas;
				else
					next_state		    <= decay_lp;
				end if;
			
			-- "A digital comparator was used for the Sustain function. The upper
			-- four bits of the Up/Down counter were compared to the programmed
			-- Sustain value and would stop the clock to the Envelope Generator when
			-- the counter counted down to the Sustain value. This created 16 linearly
			-- spaced sustain levels without havingto go through a look-up table
			-- translation between the 4-bit register value and the 8-bit Envelope
			-- Generator output. It also meant that sustain levels were adjustable
			-- in steps of 16. Again, more register bits would have provided higher
			-- resolution."
			-- "When the Gate bit was cleared, the clock would again be enabled,
			-- allowing the counter to count down to zero. Like an analog envelope
			-- generator, the SID Envelope Generator would track the Sustain level
			-- if it was changed to a lower value during the Sustain portion of the
			-- envelope, however, it would not count UP if the Sustain level were set
			-- higher." Instead it would count down to '0'.
			when sustain =>
				divider_value 		    <= 0;
				Dec_rel_sel				<='1';			-- select release as input for decay/release table
				if gate = '0' then	
					next_state 			<= releas;
				elsif (env_counter(7 downto 4) = Sus_Rel(7 downto 4)) then
					next_state 		    <= sustain;
				else
					next_state 		    <= decay;
				end  if;
		
			when releas =>
				divider_rst 			<= '1';
				exp_table_active 	    <= '1';		-- activate exponential look-up table
				env_cnt_up	 			<= '0';		-- envelope env_counter must count down (decrement)
				divider_value 		    <= divider_dec_rel;
				Dec_rel_sel				<= '1';		-- select release as input for decay/release table
				next_state 				<= release_lp;
					
			when release_lp =>
				exp_table_active 	    <= '1';		-- activate exponential look-up table
				env_count_hold_B 	    <= '0';		-- enable envelope env_counter
				env_cnt_up	 			<= '0';		-- envelope env_counter must count down (decrement)
				divider_value 		    <= divider_dec_rel;
				Dec_rel_sel				<= '1';		-- select release as input for decay/release table
				if env_counter = "00000000" then
					next_state 			<= idle;
				elsif gate = '1' then
					next_state 		    <= idle;
				else
					next_state		    <= release_lp;
				end if;

			when others =>
				divider_value 	        <= 0;
				Dec_rel_sel			    <= '0';		-- select decay as input for decay/release table
				next_state			    <= idle;	
		end case;
	end if;
end process;

Decay_Release_input_select:process(Dec_rel_sel, Att_dec, Sus_Rel)
begin
	if (Dec_rel_sel = '0') then
		Dec_rel(3 downto 0)	<= Att_dec(3 downto 0);
	else
		Dec_rel(3 downto 0)	<= Sus_rel(3 downto 0);
	end if;
end process;

-- 8 bit up/down env_counter
Envelope_counter:process(clk_1MHz)
begin
	if rising_edge(clk_1MHz) then
		if ((reset = '1') or (env_cnt_clear = '1')) then
			env_counter <= (others => '0');		
		elsif (env_count_hold_A = '1') or (env_count_hold_B = '1') then
			env_counter <= env_counter;			
		elsif (env_cnt_up = '1') then
			env_counter <= env_counter + 1;
		else
			env_counter <= env_counter - 1;
		end if;
	end if;
end process;

-- Divider	:
-- "A programmable frequency divider was used to set the various rates
-- (unfortunately I don't remember how many bits the divider was, either 12
-- or 16 bits). A small look-up table translated the 16 register-programmable
-- values to the appropriate number to load into the frequency divider.
-- Depending on what state the Envelope Generator was in (i.e. ADS or R), the
-- appropriate register would be selected and that number would be translated
-- and loaded into the divider. Obviously it would have been better to have
-- individual bit control of the divider which would have provided great
-- resolution for each rate, however I did not have enough silicon area for a
-- lot of register bits. Using this approach, I was able to cram a wide range
-- of rates into 4 bits, allowing the ADSR to be defined in two bytes instead
-- of eight. The actual numbers in the look-up table were arrived at
-- subjectively by setting up typical patches on a Sequential Circuits Pro-1
-- and measuring the envelope times by ear (which is why the available rates
-- seem strange)!"
prog_freq_div:process(clk_1MHz)
begin
	if rising_edge(clk_1MHz) then
		if (reset = '1') or (divider_rst = '1') then
			env_count_hold_A <= '1';			
			divider_counter	<= 0;
		elsif (divider_counter = 0) then
			env_count_hold_A <= '0';
			if (exp_table_active = '1') then
				divider_counter	<= exp_table_value;
			else
				divider_counter	<= divider_value;
			end if;
		else
			env_count_hold_A <= '1';					
			divider_counter	<= divider_counter - 1;
		end if;
	end if;
end process;

-- Piese-wise linear approximation of an exponential :
-- "In order to more closely model the exponential decay of sounds, another
-- look-up table on the output of the Envelope Generator would sequentially
-- divide the clock to the Envelope Generator by two at specific counts in the
-- Decay and Release cycles. This created a piece-wise linear approximation of
-- an exponential. I was particularly happy how well this worked considering
-- the simplicity of the circuitry. The Attack, however, was linear, but this
-- sounded fine."
-- The clock is divided by two at specific values of the envelope generator to
-- create an exponential.  
Exponential_table:process(env_counter, divider_value)
BEGIN
	case CONV_INTEGER(env_counter) is
		when   0 to  51 =>	exp_table_value <= divider_value * 16;
		when  52 to 101 =>	exp_table_value <= divider_value * 8;
		when 102 to 152 =>	exp_table_value <= divider_value * 4;
		when 153 to 203 =>	exp_table_value <= divider_value * 2;
		when 204 to 255 =>	exp_table_value <= divider_value;
		when others		=>	exp_table_value <= divider_value;
	end case;
end process;

-- Attack Lookup table :
-- It takes 255 clock cycles from zero to peak value. Therefore the divider
-- equals (attack rate / clockcycletime of 1MHz clock) / 254; 
Attack_table:process(Att_dec)
begin
	case Att_dec(7 downto 4) is
		when "0000"	=>	divider_attack <= 8;		--attack rate: (   2mS / 1uS per clockcycle) /254 steps
		when "0001" =>	divider_attack <= 31;		--attack rate: (   8mS / 1uS per clockcycle) /254 steps
		when "0010" =>	divider_attack <= 63;		--attack rate: (  16mS / 1uS per clockcycle) /254 steps
		when "0011" =>	divider_attack <= 94;		--attack rate: (  24mS / 1uS per clockcycle) /254 steps
		when "0100" =>	divider_attack <= 150;		--attack rate: (  38mS / 1uS per clockcycle) /254 steps
		when "0101" =>	divider_attack <= 220;		--attack rate: (  56mS / 1uS per clockcycle) /254 steps
		when "0110" =>	divider_attack <= 268;		--attack rate: (  68mS / 1uS per clockcycle) /254 steps
		when "0111" =>	divider_attack <= 315;		--attack rate: (  80mS / 1uS per clockcycle) /254 steps
		when "1000" =>	divider_attack <= 394;		--attack rate: ( 100mS / 1uS per clockcycle) /254 steps
		when "1001" =>	divider_attack <= 984;		--attack rate: ( 250mS / 1uS per clockcycle) /254 steps
		when "1010" =>	divider_attack <= 1968;		--attack rate: ( 500mS / 1uS per clockcycle) /254 steps
		when "1011" =>	divider_attack <= 3150;		--attack rate: ( 800mS / 1uS per clockcycle) /254 steps
		when "1100" =>	divider_attack <= 3937;		--attack rate: (1000mS / 1uS per clockcycle) /254 steps
		when "1101" =>	divider_attack <= 11811;	--attack rate: (3000mS / 1uS per clockcycle) /254 steps
		when "1110" =>	divider_attack <= 19685;	--attack rate: (5000mS / 1uS per clockcycle) /254 steps
		when "1111" =>	divider_attack <= 31496;	--attack rate: (8000mS / 1uS per clockcycle) /254 steps
		when others =>	divider_attack <= 31496;	--
	end case;
end process;

-- Decay Lookup table :
-- It takes 32 * 51 = 1632 clock cycles to fall from peak level to zero. 
-- Release Lookup table :
-- It takes 32 * 51 = 1632 clock cycles to fall from peak level to zero. 
Decay_Release_table:process(Dec_rel)
begin
    case Dec_rel(3 downto 0) is
	    when "0000" =>	divider_dec_rel <= 3;		--release rate: (    6mS / 1uS per clockcycle) / 1632
		when "0001" =>	divider_dec_rel <= 15;		--release rate: (   24mS / 1uS per clockcycle) / 1632
		when "0010" =>	divider_dec_rel <= 29;		--release rate: (   48mS / 1uS per clockcycle) / 1632
		when "0011" =>	divider_dec_rel <= 44;		--release rate: (   72mS / 1uS per clockcycle) / 1632
		when "0100" =>	divider_dec_rel <= 70;		--release rate: (  114mS / 1uS per clockcycle) / 1632
		when "0101" =>	divider_dec_rel <= 103;		--release rate: (  168mS / 1uS per clockcycle) / 1632
		when "0110" =>	divider_dec_rel <= 125;		--release rate: (  204mS / 1uS per clockcycle) / 1632
		when "0111" =>	divider_dec_rel <= 147;		--release rate: (  240mS / 1uS per clockcycle) / 1632
		when "1000" =>	divider_dec_rel <= 184;		--release rate: (  300mS / 1uS per clockcycle) / 1632
		when "1001" =>	divider_dec_rel <= 459;		--release rate: (  750mS / 1uS per clockcycle) / 1632
		when "1010" =>	divider_dec_rel <= 919;		--release rate: ( 1500mS / 1uS per clockcycle) / 1632
		when "1011" =>	divider_dec_rel <= 1471;	--release rate: ( 2400mS / 1uS per clockcycle) / 1632
		when "1100" =>	divider_dec_rel <= 1838;	--release rate: ( 3000mS / 1uS per clockcycle) / 1632
		when "1101" =>	divider_dec_rel <= 5515;	--release rate: ( 9000mS / 1uS per clockcycle) / 1632
		when "1110" =>	divider_dec_rel <= 9191;	--release rate: (15000mS / 1uS per clockcycle) / 1632
		when "1111" =>	divider_dec_rel <= 14706;	--release rate: (24000mS / 1uS per clockcycle) / 1632
		when others =>	divider_dec_rel <= 14706;	--
	end case;
end process;

end Behavioral;