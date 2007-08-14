------------------------------------------------------------------------------
--                                                                          --
--                 GNAT RUN-TIME LIBRARY (GNARL) COMPONENTS                 --
--                                                                          --
--     S Y S T E M . S T A C K _ C H E C K I N G . O P E R A T I O N S      --
--                                                                          --
--                                  B o d y                                 --
--                                                                          --
--          Copyright (C) 1999-2007, Free Software Foundation, Inc.         --
--                                                                          --
-- GNARL is free software; you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 2,  or (at your option) any later ver- --
-- sion. GNARL is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License --
-- for  more details.  You should have  received  a copy of the GNU General --
-- Public License  distributed with GNARL; see file COPYING.  If not, write --
-- to  the  Free Software Foundation,  51  Franklin  Street,  Fifth  Floor, --
-- Boston, MA 02110-1301, USA.                                              --
--                                                                          --
-- As a special exception,  if other files  instantiate  generics from this --
-- unit, or you link  this unit with other files  to produce an executable, --
-- this  unit  does not  by itself cause  the resulting  executable  to  be --
-- covered  by the  GNU  General  Public  License.  This exception does not --
-- however invalidate  any other reasons why  the executable file  might be --
-- covered by the  GNU Public License.                                      --
--                                                                          --
-- GNARL was developed by the GNARL team at Florida State University.       --
-- Extensive contributions were provided by Ada Core Technologies, Inc.     --
--                                                                          --
------------------------------------------------------------------------------

--  This is the VxWorks version of this package.
--  This file should be kept synchronized with the general implementation
--  provided by s-stchop.adb.

pragma Restrictions (No_Elaboration_Code);
--  We want to guarantee the absence of elaboration code because the
--  binder does not handle references to this package.

with Ada.Exceptions;

with System.Storage_Elements; use System.Storage_Elements;
with System.Parameters; use System.Parameters;
with System.Soft_Links;
with Interfaces.C;

package body System.Stack_Checking.Operations is

   --  In order to have stack checking working appropriately on VxWorks we need
   --  to extract the stack size information from the VxWorks kernel itself. It
   --  means that the library for showing task-related information needs to be
   --  linked into the VxWorks system, when using stack checking. The TaskShow
   --  library can be linked into the VxWorks system by either:

   --    * defining INCLUDE_SHOW_ROUTINES in config.h when using
   --      configuration header files, or

   --    * selecting INCLUDE_TASK_SHOW when using the Tornado project
   --      facility.

   function Set_Stack_Info
     (Stack : not null access Stack_Access) return Stack_Access;

   --  The function Set_Stack_Info is the actual function that updates the
   --  cache containing a pointer to the Stack_Info. It may also be used for
   --  detecting asynchronous abort in combination with Invalidate_Self_Cache.

   --  Set_Stack_Info should do the following things in order:
   --     1) Get the Stack_Access value for the current task
   --     2) Set Stack.all to the value obtained in 1)
   --     3) Optionally Poll to check for asynchronous abort

   --  This order is important because if at any time a write to the stack
   --  cache is pending, that write should be followed by a Poll to prevent
   --  loosing signals.

   --  Note: This function must be compiled with Polling turned off

   --  Note: on systems like VxWorks and Linux with real thread-local storage,
   --        Set_Stack_Info should return an access value for such local
   --        storage. In those cases the cache will always be up-to-date.

   --  The following constants should be imported from some system-specific
   --  constants package. The constants must be static for performance reasons.

   ----------------------------
   -- Invalidate_Stack_Cache --
   ----------------------------

   procedure Invalidate_Stack_Cache (Any_Stack : Stack_Access) is
      pragma Warnings (Off, Any_Stack);
   begin
      Cache := Null_Stack;
   end Invalidate_Stack_Cache;

   -----------------------------
   -- Notify_Stack_Attributes --
   -----------------------------

   procedure Notify_Stack_Attributes
     (Initial_SP : System.Address;
      Size       : System.Storage_Elements.Storage_Offset)
   is
      --  We retrieve the attributes directly from Set_Stack_Info below, so
      --  this implementation has nothing to do.

      pragma Unreferenced (Initial_SP);
      pragma Unreferenced (Size);

   begin
      null;
   end Notify_Stack_Attributes;

   --------------------
   -- Set_Stack_Info --
   --------------------

   function Set_Stack_Info
     (Stack : not null access Stack_Access) return Stack_Access
   is
      type OS_Stack_Info is record
         Size  : Interfaces.C.int;
         Base  : System.Address;
         Limit : System.Address;
      end record;
      pragma Convention (C, OS_Stack_Info);
      --  Type representing the information that we want to extract from the
      --  underlying kernel.

      procedure Get_Stack_Info (Stack : not null access OS_Stack_Info);
      pragma Import (C, Get_Stack_Info, "__gnat_get_stack_info");
      --  Procedure that fills the stack information associated to the
      --  currently executing task.

      My_Stack  : Stack_Access;
      Task_Info : aliased OS_Stack_Info;

   begin
      --  The order of steps 1 .. 3 is important, see specification

      --  1) Get the Stack_Access value for the current task

      My_Stack := Soft_Links.Get_Stack_Info.all;

      if My_Stack.Base = Null_Address then

         --  First invocation. Ask the VxWorks kernel about stack values

         Get_Stack_Info (Task_Info'Access);

         My_Stack.Size  := Storage_Elements.Storage_Offset (Task_Info.Size);
         My_Stack.Base  := Task_Info.Base;
         My_Stack.Limit := Task_Info.Limit;

      end if;

      --  2) Set Stack.all to the value obtained in 1)

      Stack.all := My_Stack;

      --  3) Optionally Poll to check for asynchronous abort

      if Soft_Links.Check_Abort_Status.all /= 0 then
         raise Standard'Abort_Signal;
      end if;

      --  Never trust the cached value, return local copy!

      return My_Stack;
   end Set_Stack_Info;

   -----------------
   -- Stack_Check --
   -----------------

   function Stack_Check
     (Stack_Address : System.Address) return Stack_Access
   is
      type Frame_Marker is null record;

      Marker        : Frame_Marker;
      Cached_Stack  : constant Stack_Access := Cache;
      Frame_Address : constant System.Address := Marker'Address;

   begin
      --  The parameter may have wrapped around in System.Address arithmetics.
      --  In that case, we have no other choices than raising the exception.

      if (Stack_Grows_Down and then Stack_Address > Frame_Address)
        or else (not Stack_Grows_Down and then Stack_Address < Frame_Address)
      then
         Ada.Exceptions.Raise_Exception
           (E       => Storage_Error'Identity,
            Message => "stack overflow detected");
      end if;

      --  This function first does a "cheap" check which is correct if it
      --  succeeds. In case of failure, the full check is done. Ideally the
      --  cheap check should be done in an optimized manner, or be inlined.

      if (Stack_Grows_Down
          and then Frame_Address <= Cached_Stack.Base
          and then Stack_Address > Cached_Stack.Limit)
        or else (not Stack_Grows_Down
                   and then Frame_Address >= Cached_Stack.Base
                   and then Stack_Address < Cached_Stack.Limit)
      then
         --  Cached_Stack is valid as it passed the stack check

         return Cached_Stack;
      end if;

      Full_Check :
      declare
         My_Stack : constant Stack_Access := Set_Stack_Info (Cache'Access);
         --  At this point Stack.all might already be invalid, so it is
         --  essential to use our local copy of Stack!

      begin
         if (Stack_Grows_Down
               and then Stack_Address < My_Stack.Limit)
           or else (not Stack_Grows_Down
                      and then Stack_Address > My_Stack.Limit)
         then
            Ada.Exceptions.Raise_Exception
              (E       => Storage_Error'Identity,
               Message => "stack overflow detected");
         end if;

         return My_Stack;
      end Full_Check;
   end Stack_Check;

   ------------------------
   -- Update_Stack_Cache --
   ------------------------

   procedure Update_Stack_Cache (Stack : Stack_Access) is
   begin
      if not Multi_Processor then
         Cache := Stack;
      end if;
   end Update_Stack_Cache;

end System.Stack_Checking.Operations;
