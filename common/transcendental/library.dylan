module: Dylan-User
author: Nick Kramer (nkramer@cs.cmu.edu)
synopsis: Definition of the Transcendental library.
rcs-header: $Header: /home/housel/work/rcs/gd/src/common/transcendental/library.dylan,v 1.1 1996/10/06 13:27:30 nkramer Exp $

//======================================================================
//
// Copyright (c) 1996  Carnegie Mellon University
// All rights reserved.
// 
// Use and copying of this software and preparation of derivative
// works based on this software are permitted, including commercial
// use, provided that the following conditions are observed:
// 
// 1. This copyright notice must be retained in full on any copies
//    and on appropriate parts of any derivative works.
// 2. Documentation (paper or online) accompanying any system that
//    incorporates this software, or any part of it, must acknowledge
//    the contribution of the Gwydion Project at Carnegie Mellon
//    University.
// 
// This software is made available "as is".  Neither the authors nor
// Carnegie Mellon University make any warranty about the software,
// its performance, or its conformity to any specification.
// 
// Bug reports, questions, comments, and suggestions should be sent by
// E-mail to the Internet address "gwydion-bugs@cs.cmu.edu".
//
//======================================================================

define library Transcendental
  use Dylan;
  export Transcendental;
end library Transcendental;

define module Transcendental
  use Dylan;
  use %Transcendental, 
    import: all,
    export: all;
end module Transcendental;