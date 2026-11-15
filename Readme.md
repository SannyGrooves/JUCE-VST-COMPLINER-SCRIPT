# Ask ai to make:
Vst3 plugin that uses ... to make... to (your needs)
give me the CMakeLists.txt, Juce source files .cpp .h files with Hise look and feel gui.

# Use the automated build script
Copy the output files of Claude or any other Ai into the 'Source' folder.
Right click on the [Build.ps1]check 'unblock file'
# if not opening powershell.. open with Powershell ISE as Admin
Open with powershell as admin and wait for the build.
The plugin appears under `build/folder_artefacts/Release/VST3/`.




# Requirements
CMake 3.22 or newer, Git, a C++17 compiler. 
Needed to build: [Cmake](https://cmake.org/download/)
Windows: Visual Studio 2022 (or Build Tools) with the C++ workload.
macOS: Xcode command line tools. Linux: GCC/Clang plus the usual JUCE dependencies (ALSA, X11, freetype, etc.).
Internet access on the first configure (JUCE 8.0.4 is fetched with FetchContent).

# Build
CMake (any platform)
cmake -B build -S .
cmake --build build --config Release --parallel
The plugin appears under build/SP16Controller_artefacts/Release/VST3/.

# PowerShell script (Windows)
.\build.ps1                    # Release build
.\build.ps1 -Config Debug      # Debug build
.\build.ps1 -Clean             # delete the build folder first
.\build.ps1 -Install           # copy to Common Files\VST3 (needs an Administrator PowerShell)
The script checks for cmake, git and the Visual Studio C++ tools, and prints the winget command for anything missing.

# Install locations (VST3)
OS	        Folder
Windows 	C:\Program Files\Common Files\VST3
macOS	    /Library/Audio/Plug-Ins/VST3 (all users) or ~/Library/Audio/Plug-Ins/VST3
Linux	    ~/.vst3 or /usr/lib/vst3
Rescan plugins in your DAW afterwards.

## Files

| File | Purpose |
|---|---|
| `CMakeLists.txt` | CMake project, fetches JUCE 8.0.4 |
| `build.ps1` | Windows build/install script |
| `README.md` | This file |
| `README.html` | Same content as one self-contained HTML page |
| `Source/PluginProcessor.h` | Processor class, parameter IDs, shared name lists |
| `Source/PluginProcessor.cpp` | Parameters, MIDI processing, chords, arpeggiator |
| `Source/PluginEditor.h` / `.cpp` | Editor window: layout, panels, attachments |
| `Source/HiseLookAndFeel.h` / `.cpp` | HISE-style look and feel: knobs, glossy buttons, LEDs, panels |