module:      operating-system
rcs-header:  $Header: /scm/cvs/src/common/system/Attic/posix-os.dylan,v 1.3 1999/04/09 16:15:03 tree Exp $
author:      Tom Emerson, tree@tiac.net
             [based on stubs from Eric Kidd]
copyright:   Copyright 1999 Thomas R. Emerson
synopsis:    Implementation of Harlequin Dylan 1.2 operating-system library
             for POSIX compatible operating-systems.

/*
   Copyright (C) 1999 Thomas R. Emerson

   This program is free software; you can redistribute it and/or
   modify it under the terms of the GNU General Public License
   as published by the Free Software Foundation; either version 2
   of the License, or (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

   Bug reports, questions, comments, and suggestions should be sent by
   E-mail to the Internet address "gwydion-bugs@randomhacks.com".
*/

define function login-name()
 => (name :: false-or(<string>))
  let name = call-out("getlogin", ptr:);
  if (as(<statically-typed-pointer>, name) ~= null-pointer)
    import-value(<byte-string>, make(<c-string>, pointer: name));
  else
    #f;
  end if;
end;

define function login-group()
 => (group :: false-or(<string>))
  let group = make(<c-string>, size: 16);
  let tmp = call-out("primary_group_name", int:, ptr: group.raw-value, int: 32);
  if (tmp = 0)
    import-value(<byte-string>, group);
  else
    #f;
  end if;
end;

define function owner-name()
 => (group :: false-or(<string>))
  #f;
end;

define function owner-organization()
 => (group :: false-or(<string>))
  #f;
end;

define function environment-variable(name :: <byte-string>)
 => (value :: false-or(<byte-string>))
  let value = call-out("getenv", ptr:, ptr: (export-value(<c-string>, name)).raw-value);
  if (as(<statically-typed-pointer>, value) ~= null-pointer)
    import-value(<byte-string>, make(<c-string>, pointer: value));
  else
    #f;
  end if;
end;
    
define function environment-variable-setter(new-value :: false-or(<byte-string>), name :: <byte-string>)
 => (value :: false-or(<byte-string>))
  if (new-value)
    let nvp = concatenate(concatenate(name, "="), new-value);
    let result = call-out("safe_putenv", int:, ptr: (export-value(<c-string>, nvp)).raw-value);
    if (result = 0)
      new-value;
    else
      #f;
    end if;
  else
    // don't care about the return value since we always return #f when unsetting
    call-out("safe_unsetenv", int:, ptr: (export-value(<c-string>, name)).raw-value);
    #f;
  end if;
end;

define function split(character :: <character>, string :: <byte-string>)
 => (components :: <vector>)

  let result = make(<stretchy-vector>);

  let current-start = 0;
  let current-offset = 0;

  for (c in string)
    current-offset := current-offset + 1;
    if (c = character)
      unless (current-start = current-offset - 1)
        // don't copy empty entries
        add!(result, copy-sequence(string, start: current-start, end: current-offset - 1));
      end unless;
      current-start := current-offset;
    end if;
  end for;

  unless(current-start = current-offset)
    // don't copy empty entries
    add!(result, copy-sequence(string, start: current-start));
  end unless;

  result;
end;

define function tokenize-environment-variable(variable :: <byte-string>, #key separator = ':')
 => (components :: <vector>)
  split(separator, variable);
end function;

define function exit-application(code :: <integer>) => ()
  exit(exit-code: code);
end function;

/*
define function tokenize-command-string
    (command-string :: <byte-string>)
 => (command :: <byte-string>, #rest arguments :: <byte-string>)
  // XXX - handle bash quoting and escape sequences, but not
  // expansion or interpolation.
end function;
*/