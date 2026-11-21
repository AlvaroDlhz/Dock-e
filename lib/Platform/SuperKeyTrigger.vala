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
	 * Fires when the Super key is pressed and released on its own, anywhere
	 * on the desktop.  Super combined with another key is left alone so the
	 * desktop's own shortcuts keep working.
	 */
	public interface SuperKeyTrigger : Object
	{
		/**
		 * Whether the key could be claimed; nothing is emitted otherwise.
		 */
		public abstract bool available { get; }

		/**
		 * The Super key was tapped.
		 *
		 * @param timestamp the time of the key release
		 */
		public signal void activated (uint32 timestamp);
	}
}
