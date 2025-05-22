# biogeophys
Modifications of CTSM's biogeophys Fortran files

## Current Issue with SaturatedExcessRunoffMod

We created a circular module dependency by importing SoilHydrologyMod in SaturatedExcessRunoffMod

1. Normal (acyclic) chain

```
Step-1 compile  SaturatedExcessRunoffMod   → writes  saturatedexcessrunoffmod.mod
Step-2 compile  InfiltrationExcessRunoffMod
               (uses SaturatedExcessRunoffMod)   → OK, .mod file exists
Step-3 compile  SoilHydrologyMod
               (uses InfiltrationExcessRunoffMod) → OK
```

2. Circular chain
```
(1) SoilHydrologyMod
        |
        |   uses
        ▼
(2) InfiltrationExcessRunoffMod
        |
        |   uses
        ▼
(3) SaturatedExcessRunoffMod     ← we added:
        ▲                           use SoilHydrologyMod
        |   uses                    (to import h2osfc)
        └───────────────────────────────┘
```

To compile `SoilHydrologyMod` the compiler first needs
`infiltrationexcessrunoffmod.mod`

To compile `InfiltrationExcessRunoffMod` it needs
`saturatedexcessrunoffmod.mod`

To compile `SaturatedExcessRunoffMod` (after the use `SoilHydrologyMod`) it needs
`soilhydrologymod.mod` ⇦ closes the loop

No module can be compiled first because each waits for another’s `.mod`.

3. How CMake reacts
CMake tries to topologically sort the modules.
When they detect a cycle they silently drop the impossible target:

```
make: Circular InfiltrationExcessRunoffMod.o <- saturatedexcessrunoffmod.mod dependency dropped
```

`SaturatedExcessRunoffMod` is skipped, no `.mod` file is produced, and the next file that uses it aborts with:

```
Fatal Error: Cannot open module file 'saturatedexcessrunoffmod.mod'
```

### Breaking the Cycle
Remove the line that created the cycle:

```
!  use SoilHydrologyMod, only : h2osfc
```

and obtain h2osfc through the associate alias that is already passed in via soilstate_inst:

```
associate( &
  … ,
  h2osfc => soilstate_inst%h2osfc_col , &
  … )
```

Could also import a different module to pull h2osfc from `SurfaceWaterMod`.

There seems to be some caveats.

## SurfaceWaterMod

h2osfc_col is stored in an instance called:

```
b_waterstate_inst%h2osfc_col
```

So this is a field of the derived type WaterStateBulkType, accessed via an instance b_waterstate_inst.

No global h2osfc variable is declared in the module — the only "h2osfc" reference in top-level scope is as part of this internal instance.

This instance (b_waterstate_inst) is not declared public, and neither is h2osfc_col. The relevant lines from the module:

```
type(waterstatebulk_type), private :: b_waterstate_inst

...
private
public :: UpdateFracH2oSfc
public :: UpdateH2osfc
```
So, even if we tried:

```
use SurfaceWaterMod, only : b_waterstate_inst
```

it would fail to compile, because b_waterstate_inst is private.

1. h2osfc is not a standalone module variable.

2. b_waterstate_inst is a private local instance.

3. No public accessor or module-level alias is exposed for h2osfc

### Possible Solution

1. Update the subroutine header
Find and change:

```
subroutine ComputeFsatTopmodel(bounds, num_hydrologyc, filter_hydrologyc, &
     soilhydrology_inst, soilstate_inst, fsat)
```

to:

```
subroutine ComputeFsatTopmodel(bounds, num_hydrologyc, filter_hydrologyc, &
     soilhydrology_inst, soilstate_inst, waterstatebulk_inst, fsat)
```

Then add this argument declaration:

```
type(waterstatebulk_type), intent(in) :: waterstatebulk_inst
```

2. Fix the associate block
Update our associate block to include this mapping:

```
associate( &
   frost_table => soilhydrology_inst%frost_table_col , &
   zwt         => soilhydrology_inst%zwt_col         , &
   zwt_perched => soilhydrology_inst%zwt_perched_col , &
   h2osfc      => waterstatebulk_inst%h2osfc_col / 1000._r8 , &  ! mm to m
   wtfact      => soilstate_inst%wtfact_col            )
```

The division by 1000._r8 converts mm (what CTSM stores) to meters (what our logic needs).

In SoilHydrologyMod.F90

3. Find the call to ComputeFsatTopmodel
Should see something like:

```
call ComputeFsatTopmodel(bounds, ncol, filter, &
                         soilhydrology_inst, soilstate_inst, fsat)
```

Update it to:

```
call ComputeFsatTopmodel(bounds, ncol, filter, &
                         soilhydrology_inst, soilstate_inst, waterstatebulk_inst, fsat)
```

4. Make sure waterstatebulk_inst is declared or passed
At the call site, waterstatebulk_inst must already exist. It’s usually passed down from higher-level routines, e.g., in the driver. If not:

Declare it:

```
use WaterStateBulkType, only : waterstatebulk_type
type(waterstatebulk_type) :: waterstatebulk_inst
```

Or make sure it’s being passed into the same calling subroutine and is in scope.

### Ideally

We can now use h2osfc(c) inside ComputeFsatTopmodel, and the compiler knows:

Where the data comes from

Its type and units (via associate)

No circular dependencies are introduced
