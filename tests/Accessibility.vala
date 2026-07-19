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
	public static void register_accessibility_tests ()
	{
		Test.add_func ("/Services/Accessibility/describe", accessibility_describe);
		Test.add_func ("/Services/Accessibility/role", accessibility_role);
		Test.add_func ("/Services/Accessibility/keyboard-navigation", accessibility_keyboard_navigation);
	}

	void accessibility_describe ()
	{
		var button = new Gtk.Button ();
		Accessibility.describe (button, "Reset timer", "Restarts the current session");
		assert (button.get_accessible ().get_name () == "Reset timer");
		assert (button.get_accessible ().get_description () == "Restarts the current session");
	}

	void accessibility_role ()
	{
		var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
		Accessibility.set_role (box, Atk.Role.ALERT);
		assert (box.get_accessible ().get_role () == Atk.Role.ALERT);
	}

	void accessibility_keyboard_navigation ()
	{
		var window = new Gtk.Window ();
		var context = window.get_style_context ();

		Accessibility.set_keyboard_navigation (window, true);
		assert (context.has_class (Accessibility.KEYBOARD_NAVIGATION_CLASS));

		Accessibility.set_keyboard_navigation (window, false);
		assert (!context.has_class (Accessibility.KEYBOARD_NAVIGATION_CLASS));
	}
}
