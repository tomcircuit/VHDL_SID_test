#
# create a python script to simulate a direct digital synthesis waveform generator, using a 24bit phase accumulator
# and a 12bit waveform output. The phase accumulator should increment by a configurable 16 bit value at 1 microsecond
# intervals. The simulation should run for 10 milliseconds. The simulation should output a comma separated value
# file. each line of the file should include simulation time in microseconds, the accumulator value in decimal, and
# the 12 most significant bits of the accumulator value in signed decimal format.
#
# AskAI 5/7/2025 10:07 AM 
#
# Direct Digital Synthesis Waveform Generator Simulation
# This Python script simulates a direct digital synthesis waveform generator using a 24-bit phase accumulator and a
# 12-bit waveform output. The phase accumulator increments by a configurable 16-bit value at 1 microsecond intervals.
# The simulation runs for 10 milliseconds and outputs a comma-separated value (CSV) file.
#
# Simulation Parameters
# Phase accumulator bit width: 24 bits
# Waveform output bit width: 12 bits
# Increment value bit width: 16 bits
# Simulation time: 2 milliseconds (10,000 microseconds)
# Time interval: 1 microsecond


import csv
from scipy.io import savemat

class LFSR:
    def __init__(self, seed, taps):
        self.state = seed
        self.taps = taps

    def step(self):
        xor = 0
        for t in self.taps:
            xor ^= (self.state >> t) & 1
        self.state = (self.state >> 1) | (xor << (22 - 1))
        return self.state

    def run(self, steps):
        output = []
        for _ in range(steps):
            output.append(self.step())
        return output

def to_signed_12bit(value):
    # Mask to 12 bits
    value &= 0xFFF
    # Check if the value is negative
    if value & 0x800:
        value -= 0x1000
    return value

# Simulation parameters
phase_accumulator_bit_width = 24
waveform_output_bit_width = 12
increment_value_bit_width = 16
lfsr_accumulator_clock_bit = 22
lfsr_bit_width = 22

simulation_time_us = 10000
time_interval_us = 1


# Configurable increment value (16-bit)
increment_value = 0xF2F0  # Example value, adjust as needed

# Configurable pulse width control (12-bit)
pulse_width_value = 0x03FF

# Configurable attack control (4-bit)
attack_value = 1

# Configurable decay control (4-bit)
decay_value = 2

# Configurable sustain control (4-bit)
sustain_value = 7

# Configurable release control (4-bit)
release_value = 0

### Initialization ###

# Initialize phase accumulator
phase_accumulator = 0
old_phase_accumulator = 0

# Initialize noice LFSR
lfsr_seed = 1  # Initial seed
lfsr_taps = [0, 17]      # Tap positions
lfsr = LFSR(lfsr_seed, lfsr_taps)
lfsr_value = lfsr.step()

#determine size of output vectors
size = int(float(simulation_time_us / time_interval_us))

#create some vectors for export .
triangle_vector = [0] * size
sawtooth_vector = [0] * size
pulse_vector = [0] * size

# Open output CSV file
with open('dds_simulation.csv', 'w', newline='') as csvfile:
    writer = csv.writer(csvfile)

    # Write header row
    writer.writerow(['Increment value',increment_value])
    writer.writerow(['Time (us)', 'waveform (u12)', 'saw (u12)', 'tri (u12)', 'pulse (u12)'])

    ### Run simulation ###
    for time_us in range(0, simulation_time_us, time_interval_us):
    
        #### SID WAVEFORM GENERATOR ###
    
        # Increment phase accumulator
        old_accumulator = phase_accumulator
        phase_accumulator = (phase_accumulator + increment_value) & ((1 << phase_accumulator_bit_width) - 1)
        
        # Check for LFSR clock event
        if phase_accumulator & (1 << 22) != old_phase_accumulator & (1 << 22):
            lfsr_value = lfsr.step()

        # Extract 12 most significant bits of accumulator value
        waveform_output = phase_accumulator >> (phase_accumulator_bit_width - waveform_output_bit_width)
        waveform_output &= 0x0FFF
        
        # Sawtooth waveform :        
        # "The Sawtooth waveform was created by sending the upper 12-bits of the
        # accumulator to the 12-bit Waveform D/A."        
        
        # Create sawtooth waveform output 
        sawtooth_output = to_signed_12bit(waveform_output ^ 0x0800)
            
        # Triangle waveform :
        # "The Triangle waveform was created by using the MSB of the accumulator to
        # invert the remaining upper 11 accumulator bits using EXOR gates. These 11
        # bits were then left-shifted (throwing away the MSB) and sent to the Waveform
        # D/A (so the resolution of the triangle waveform was half that of the sawtooth,
        # but the amplitude and frequency were the same). "            
            
        # Create triangle waveform output      
        if (waveform_output & 0x0800):
            triangle_xor_mask = 0x0FFF
        else:
            triangle_xor_mask = 0x0000
        triangle_output = to_signed_12bit((((waveform_output << 1) & 0x0FFF) ^ triangle_xor_mask) ^ 0x0800)

        # Pulse waveform :
        # "The Pulse waveform was created by sending the upper 12-bits of the
        # accumulator to a 12-bit digital comparator. The output of the comparator was
        # either a one or a zero. This single output was then sent to all 12 bits of
        # the Waveform D/A. "
        
        # Create pulse waveform output      
        if (waveform_output < pulse_width_value):
            pulse_output = to_signed_12bit(0x0800)
        else:
            pulse_output = to_signed_12bit(0x07FF)
            
        # Noise (23-bit Linear Feedback Shift Register, max combinations = 8388607) :
        # "The Noise waveform was created using a 23-bit pseudo-random sequence
        # generator (i.e., a shift register with specific outputs feed back to the input
        # through combinatorial logic). The shift register was clocked by one of the
        # intermediate bits of the accumulator to keep the frequency content of the
        # noise waveform relatively the same as the pitched waveforms.
        # The upper 12-bits of the shift register were sent to the Waveform D/A."

        # Create noise waveform output        
        noise_output = lfsr_value >> (lfsr_bit_width - waveform_output_bit_width)
        
        #### SID ENVELOPE GENERATOR ###
        envelope = 127      

        voice_out = triangle_output * envelope
        
        # Write output row
        writer.writerow([time_us, waveform_output, sawtooth_output, triangle_output, pulse_output, noise_output, voice_out])     

        # add outputs to vectors
        triangle_vector[time_us] = triangle_output
        pulse_vector[time_us] = pulse_output
        sawtooth_vector[time_us] = sawtooth_output
        
data = { 'triangle' : triangle_vector, 'sawtooth' : sawtooth_vector, 'pulse' : pulse_vector }
# Save the data to a .mat file
savemat('sid_voice.mat', data)
print("MAT file 'sid_voice.mat' has been created successfully!")
        
        
        
        

    





 
		
