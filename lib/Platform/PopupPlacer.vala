//
//  Copyright (C) 2026 Dock-E
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

namespace Plank.Platform
{
	/**
	 * What a window shown next to the dock is.
	 */
	public enum PopupKind
	{
		/** A tooltip of a dock item */
		TOOLTIP,
		/** Previews of windows, shown on hover */
		PREVIEW,
		/** A panel which takes the keyboard: launcher, tray, workspaces */
		PANEL,
		/** An animation drawn over everything else */
		OVERLAY
	}

	/**
	 * Shows the windows which belong to the dock (tooltips, previews,
	 * panels) where the dock wants them.
	 */
	public interface PopupPlacer : Object
	{
		/**
		 * Tells the display server what the window is.  Call it before the
		 * window is realized.
		 */
		public abstract void setup (Gtk.Window popup, PopupKind kind);

		/**
		 * Moves the window to where the dock computed it should go.
		 *
		 * @param popup the window
		 * @param x the left edge in GDK screen coordinates
		 * @param y the top edge in GDK screen coordinates
		 * @param anchor what the window belongs to (a dock item, in GDK
		 *        screen coordinates), for backends which place windows
		 *        relative to another one; null to use x and y only
		 */
		public abstract void place (Gtk.Window popup, int x, int y, Gdk.Rectangle? anchor = null);
	}

	/**
	 * Places windows with plain GTK calls at global coordinates, where the
	 * display server allows it ({@link Capability.ABSOLUTE_PLACEMENT}).
	 */
	public class AbsolutePopupPlacer : Object, PopupPlacer
	{
		public void setup (Gtk.Window popup, PopupKind kind)
		{
			switch (kind) {
			case PopupKind.TOOLTIP:
				popup.type_hint = Gdk.WindowTypeHint.TOOLTIP;
				break;
			case PopupKind.PREVIEW:
				popup.set_keep_above (true);
				popup.type_hint = Gdk.WindowTypeHint.POPUP_MENU;
				break;
			case PopupKind.PANEL:
				popup.set_keep_above (true);
				popup.type_hint = Gdk.WindowTypeHint.DIALOG;
				break;
			case PopupKind.OVERLAY:
				popup.type_hint = Gdk.WindowTypeHint.DOCK;
				popup.set_keep_above (true);
				break;
			}
		}

		public void place (Gtk.Window popup, int x, int y, Gdk.Rectangle? anchor = null)
		{
			popup.move (x, y);
		}
	}

	static PopupPlacer? fallback_placer = null;

	/**
	 * The popup placer of the backend; without a backend, as in some tests,
	 * windows are placed at global coordinates.
	 */
	public unowned PopupPlacer get_popup_placer ()
	{
		unowned Backend? backend = get_backend ();
		if (backend != null)
			return backend.popups;

		if (fallback_placer == null)
			fallback_placer = new AbsolutePopupPlacer ();
		return fallback_placer;
	}
}
