//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//
//  Plank is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

using Plank;

namespace PlankTests
{
	public static void register_audio_service_tests ()
	{
		Test.add_func ("/Services/AudioService/parse-volume", audio_service_parse_volume);
		Test.add_func ("/Services/AudioService/reject-invalid-volume", audio_service_reject_invalid_volume);
	}

	void audio_service_parse_volume ()
	{
		double volume;
		bool muted;
		assert (AudioService.parse_volume_output ("Volume: 0.42", out volume, out muted));
		assert (Math.fabs (volume - 0.42) < 0.0001);
		assert (!muted);
		assert (AudioService.parse_volume_output ("Volume: 1.25 [MUTED]\n", out volume, out muted));
		assert (Math.fabs (volume - 1.25) < 0.0001);
		assert (muted);
	}

	void audio_service_reject_invalid_volume ()
	{
		double volume;
		bool muted;
		assert (!AudioService.parse_volume_output ("unavailable", out volume, out muted));
	}
}
