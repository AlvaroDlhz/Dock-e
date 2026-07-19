//
//  Copyright (C) 2013 Rico Tzschichholz
//
//  This file is part of Plank.
//
//  Plank is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Plank is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

using Plank;

namespace PlankTests
{
	public const string TEST_ICON = Config.DATA_DIR + "/test-icon.svg";
	public const string TEST_DOCK_NAME = "test1";
	public const uint IO_WAIT_MS = 1500;
	public const uint EVENT_WAIT_MS = 100;
	public const uint X_WAIT_MS = 200;
	
	public static int main (string[] args)
	{
		Test.init (ref args);
		
		Gtk.init (ref args);
		
		Log.set_always_fatal (LogLevelFlags.LEVEL_ERROR | LogLevelFlags.LEVEL_CRITICAL);
		
		Paths.initialize ("test", Config.DATA_DIR);
		internal_quarks_initialize ();
		
		// static tests
		register_accessibility_tests ();
		register_audio_service_tests ();
		register_application_uninstall_service_tests ();
		register_bluetooth_service_tests ();
		register_brightness_service_tests ();
		register_command_runner_tests ();
		register_network_service_tests ();
		register_power_service_tests ();
		register_status_notice_model_tests ();
		register_system_tests ();
		register_update_service_tests ();
		register_drawing_tests ();
		register_items_tests ();
		register_preferences_tests ();
		register_widgets_tests ();

		// further preparations needed for runtime tests
		//Factory.init (new TestMain (), new ItemFactory ());
		//Logger.initialize ("test");
		//Paths.ensure_directory_exists (Paths.AppConfigFolder.get_child (TEST_DOCK_NAME));
		//WindowControl.initialize ();
		
		// runtime tests
		//register_controller_tests ();
		
		return Test.run ();
	}
	
	void wait (uint milliseconds)
	{
		var main_loop = new MainLoop ();
		
		Gdk.threads_add_timeout (milliseconds, () => {
			main_loop.quit ();
			return false;
		});
		
		main_loop.run ();
	}
}
