
%% load 1MHz SID voice output 
fs = 1e+06;
t = 0:1/fs:0.10;
sig = csvread('long_triangle_envelope.csv');
% plot(t,sig);  
% figure; pspectrum(sig,fs, "spectrogram");

%% prepare to decimate to ~96KHz sample rate
factor = 11;
lowfs = fs/factor
lowt = 0:1/lowfs:0.10;

%% start by filtering below newfs/2 to avoid aliasing
order = 5;
fc = 43000;
lowcut = fc/fs;
[b,a] = butter(order,lowcut,'low');
lowfilt = filtfilt(b,a,sig);
%figure; plot(t,lowfilt)    
%figure; pspectrum(lowfilt,fs);

%% now downsample by factor
lowsamp = downsample(lowfilt,factor);
 
%subplot(2,1,1); plot(t,sig);
%subplot(2,1,2); plot(newt,lowsamp);
%figure; pspectrum(sig,fs);
%pspectrum(lowsamp,lowfs);

%figure; plot(newt,lowsamp);
%hold off;




