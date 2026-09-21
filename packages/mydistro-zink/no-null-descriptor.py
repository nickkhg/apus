#!/usr/bin/env python3
"""Lets Zink start on a Vulkan driver with no nullDescriptor feature.

Zink is Mesa's OpenGL on Vulkan. It refuses to start unless the Vulkan
driver reports the nullDescriptor feature of VK_KHR_robustness2. MoltenVK
reports false, as a constant, because Metal has no null descriptor:

    robustness2Features->nullDescriptor = false;   // MVKDevice.mm

So on a Mac there is no Vulkan driver that satisfies Zink, and the
compositor draws with the CPU.

The feature says what happens when a shader reads a descriptor that has
nothing bound: with it, the read gives zero, and without it the result is
undefined. A shader that binds everything it reads never asks the question.
The compositor's four shaders bind everything they read, and tests/gpu.exp
compares what this draws with what the CPU draws, pixel by pixel.

This is not a fix for Zink in general. A program with a shader that reads
an unbound slot has no answer here, and what it draws is undefined. That is
why the driver goes in a directory of its own, and only a program that asks
for it by name gets it.

See docs/gpu.md.
"""
import sys

path = sys.argv[1]
source = open(path).read()

old = """   if (!screen->info.rb2_feats.nullDescriptor) {
      mesa_loge("Zink requires the nullDescriptor feature of KHR/EXT robustness2.");
      goto fail;
   }
"""
new = """   /* mydistro: MoltenVK reports no nullDescriptor, and Metal has none.
    * See packages/mydistro-zink/no-null-descriptor.py.
    */
   if (!screen->info.rb2_feats.nullDescriptor)
      mesa_logw("ZINK: no nullDescriptor. An unbound descriptor reads undefined data.");
"""
if old not in source:
    sys.exit(f"no-null-descriptor.py: this part of {path} has changed:\n{old}")

open(path, "w").write(source.replace(old, new, 1))
print(f"no-null-descriptor.py: patched {path}")
