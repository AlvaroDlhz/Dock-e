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
	public static void register_system_tests ()
	{
		Test.add_func ("/Services/System/report-launch-failure", system_report_launch_failure);
	}

	void system_report_launch_failure ()
	{
		var context = Gdk.Display.get_default ().get_app_launch_context ();
		var system = new Plank.System (context);
		system.launch (File.new_for_path ("/dock-e-test/missing.desktop"));

		Gtk.MessageDialog? error_dialog = null;
		foreach (unowned Gtk.Window window in Gtk.Window.list_toplevels ()) {
			if (window is Gtk.MessageDialog && window.visible) {
				error_dialog = (Gtk.MessageDialog) window;
				break;
			}
		}

		assert (error_dialog != null);
		assert (error_dialog.text == "The selected item could not be opened.");
		error_dialog.response (Gtk.ResponseType.CLOSE);
		while (MainContext.default ().pending ())
			MainContext.default ().iteration (false);
		assert (!error_dialog.visible);
	}
}
