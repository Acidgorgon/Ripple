-- Ripple calibration (client half): put in StarterPlayerScripts. Counts arrivals and times the gap per packet.
local RS = game:GetService("ReplicatedStorage")
local remote = RS:WaitForChild("RippleCal")
local count = 0
remote.OnClientEvent:Connect(function()
	count += 1
end)
task.delay(60, function()
	print("[RippleCal] client received", count)
end)
