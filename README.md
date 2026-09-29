# hjson-cs

[![nuget version](https://img.shields.io/nuget/v/Hjson.svg?style=flat-square)](https://www.nuget.org/packages/Hjson/)
[![License](https://img.shields.io/github/license/hjson/hjson-cs.svg?style=flat-square)](https://github.com/hjson/hjson-cs/blob/master/LICENSE)

[Hjson](http://hjson.github.io), a user interface for JSON

![Hjson Intro](http://hjson.github.io/hjson1.gif)

JSON is easy for humans to read and write... in theory. In practice JSON gives us plenty of opportunities to make mistakes without even realizing it.

Hjson is a syntax extension to JSON. It's NOT a proposal to replace JSON or to incorporate it into the JSON spec itself. It's intended to be used like a user interface for humans, to read and edit before passing the JSON data to the machine.

```Hjson
{
  # specify rate in requests/second (because comments are helpful!)
  rate: 1000

  // prefer c-style comments?
  /* feeling old fashioned? */

  # did you notice that rate doesn't need quotes?
  hey: look ma, no quotes for strings either!

  # best of all
  notice: []
  anything: ?

  # yes, commas are optional!
}
```

Supported frameworks/runtimes include .NET Core, .NET 4.x & Mono.

This library includes two readers/writers that fully conform to the respective specification:

- JSON
- Hjson

The C# implementation of Hjson is based on [System.Json](https://github.com/mono/mono). For other platforms see [hjson.github.io](http://hjson.github.io).

# Install from nuget

```
Install-Package Hjson
```

# Usage

You can either

- use this libary directly
- or just convert Hjson to JSON and use it with your *favorite JSON library*.

### Convert

```c#
// convert Hjson to JSON
var jsonString = HjsonValue.Load(filePath).ToString();

// convert JSON to Hjson
var hjsonString = JsonValue.Load("test.json").ToString(Stringify.Hjson);
```

### Read

```c#
var jsonObject = HjsonValue.Load(filePath).Qo();
```

`HjsonValue.Load()` will accept both Hjson and JSON. You can use `JsonValue.Load()` to accept JSON input only.

### Object sample

```c#
var jsonObject = HjsonValue.Parse("{\"name\":\"hugo\",\"age\":5}").Qo();
string name = jsonObject.Qs("name");
int age = jsonObject.Qi("age");
// you may prefer to get any value as string
string age2 = jsonObject.Qstr("age");

// or iterate over the members
foreach (var item in jsonObject)
{
  Console.WriteLine("{0}: {1}", item.Key, item.Value);
}
```

### Array sample

```c#
var jsonArray = HjsonValue.Parse("[\"hugo\",5]").Qa();
string first = jsonArray[0];

// or iterate over the members
foreach (var item in jsonArray)
  Console.WriteLine(item.ToValue());
```

### Nested sample

```c#
var nested = HjsonValue.Parse("{\"partner\":{\"name\":\"John\",\"age\":23}}").Qo();
string name = nested.Qo("partner").Qs("name", "default");
int age = nested.Qo("partner").Qi("age", 77);
string gender = nested.Qo("partner").Qs("gender", "unknown");
```

### Create

```c#
var jsonObject = new JsonObject
{
  { "name", "John" },
  { "age", 23 },
};
// -> { "name": "John", "age", 23 }

JsonArray jsonArray = new JsonArray()
{
  "John",
  23,
};
// -> [ "John", 23 ]
```

### Modify

```c#
jsonObject["name"] = "Hugo";
jsonObject.Remove("age");
```

### Write

```c#
HjsonValue.Save(jsonObject, "file.hjson"); // as Hjson
HjsonValue.Save(jsonObject, "file.json"); // as JSON
```

### ToString()

```c#
jsonObject.ToString(Stringify.Hjson); // Hjson output
jsonObject.ToString(Stringify.Formatted); // formatted JSON output
jsonObject.ToString(Stringify.Plain); // plain JSON output, default
jsonObject.ToString(); // plain
```

Also see the [sample](sample).

# API

See [api.md](api.md).

## From the Commandline

A commandline tool to convert from/to Hjson is available in the cli folder.

For other tools see [hjson.github.io](http://hjson.github.io).

# Source/Projects

Solutions in the root folder target .NET Core.

Solutions for .NET 4.x can be found in the legacy folder.

# Local verification

`verify.sh` is a single entry point that proves the source tree, the test
fixtures and the published NuGet package all come from the same commit. It
works regardless of the directory you run it from (it always switches to the
repository root) and stops at the first failing stage.

To restore dependencies and compile only:

```
dotnet restore
dotnet build Hjson.slnx --no-restore
```

To run the full gate:

```
./verify.sh
cat artifacts/verification-summary.txt
find artifacts/package-a -maxdepth 1 -name '*.nupkg' -print
```

The stages run in a fixed order: restore, format check, Release build, tests,
two isolated package builds (`artifacts/package-a`, `artifacts/package-b`),
package content gate, a negative self-test, fixture gate, and a reproducible
hash comparison. Only `dotnet restore` may use the network; every later .NET
command runs with `--no-restore` and an unreachable proxy guard, so the rest
of the pipeline also works offline.

The package content gate enforces that:

- `lib/` only contains the expected target framework assets,
- `LICENSE` (identical to the repository file) and the generated XML
  documentation are inside the package,
- no file from `test/assets`, and no `cli`/`sample` output, is shipped,
- the nuspec declares no package dependencies.

The negative self-test copies the package into a throwaway output directory,
adds a stray file, asserts the gate rejects it, deletes the probe directory
and continues the normal checks.

The two packages are hashed after canonicalization (entry names and payload
hashes in sorted order): volatile ZIP container timestamps are ignored, but
the nuspec and every payload entry are part of the hash, so the metadata is
not excluded.

The package version has a single source: the `<Version>` property in
`Hjson/Hjson.csproj`.

## Summary states

`artifacts/verification-summary.txt` always lists every stage in fixed order,
even after a failure:

- `PASS`: the stage completed successfully.
- `FAIL`: the stage failed; `FAILED_STAGE` names it and the script exits
  non-zero. Details point at the log under `artifacts/logs/`.
- `SKIP`: the stage never ran, because an earlier stage failed (or because the
  pipeline aborted before reaching it).
