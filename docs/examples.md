# PicoClaw Example Prompts

A collection of things to say to ThreadWeaver (or OpenClaw) to exercise the 28 MCP tools and the installed models. Copy any prompt into the chat and hit enter.

> **Tip:** For tool-heavy workflows, use `llama3.1:8b` or switch the provider to Claude/GPT-4/Gemini. Small local models occasionally miss tool calls. See [faq.md](faq.md) #16 for details.

---

## 💡 LED Control

The `leds` MCP server has 5 tools. Every Blinkt! effect is visible on the physical strip attached to picoclaw's GPIO header.

```
Make the LEDs purple.
```

```
Flash the LEDs red three times.
```

```
Show a progress bar at 75% in green.
```

```
Celebrate — do a success pulse.
```

```
Clear the LEDs and return to the idle scanner animation.
```

```
Cycle through red, green, and blue, pausing one second between each color.
```

```
I'm about to run a long job. Show a progress bar starting at 0 and increase it to 100 in 10% steps over 30 seconds.
```

---

## 🌡️ System Monitoring

The `system` MCP server exposes 6 tools for picoclaw's system state. The LLM can combine these with LED and file tools for interesting workflows.

```
What's the CPU temperature right now?
```

```
How much memory is free on picoclaw?
```

```
How long has picoclaw been running?
```

```
Show me the current disk usage as a percentage.
```

```
What's the 1-minute load average?
```

```
What network interfaces does picoclaw have and what are their IP addresses?
```

```
Give me a one-paragraph summary of picoclaw's current state: CPU, memory, disk, uptime, and temperature.
```

---

## 🧠 Model Management (picocrush)

The `picocrush` MCP server has 4 tools for managing the Ollama inference server. These all talk to picocrush (10.1.10.221) from picoclaw via the LAN.

```
What models are installed on picocrush?
```

```
Which model is currently loaded in GPU memory?
```

```
How much GPU memory is picocrush using right now?
```

```
Pull the moondream:1.8b model from the Ollama library.
```

```
List all the models and tell me which one is the smallest.
```

---

## 🕒 Time and Dates

The `time` MCP server gives the LLM awareness of the current date and time — important because training data has a cutoff.

```
What time is it right now in local time?
```

```
What day of the week is it?
```

```
How many days until New Year's Eve?
```

```
Format 12345 seconds as days, hours, minutes, and seconds.
```

---

## 📁 Files (Sandboxed)

The `files` MCP server gives the LLM read/write/list/delete access to `/tmp/picoclcaw-sandbox` inside the ThreadWeaver container. Anything outside that directory is rejected.

```
Write a file called greeting.txt containing "Hello from PicoClaw".
```

```
Read greeting.txt back to me.
```

```
List all files in the sandbox.
```

```
Create a shopping list file with apples, bread, milk, eggs, and coffee, one per line.
```

```
Delete the old greeting.txt file.
```

```
Write a JSON file called config.json containing a dictionary with keys "name" (PicoClaw), "version" (1.0), and "features" (a list with chat, tools, and LEDs).
```

---

## 🎯 Multi-Tool Workflows

These prompts exercise several tools in sequence. Use `llama3.1:8b` or an external model for best results — smaller models sometimes miss the chaining.

```
Check the CPU temperature. If it's above 60°C, flash the LEDs red. If it's below 50°C, do a green success pulse. Otherwise set the LEDs to amber.
```

```
Check the current memory usage. Write a report to status.txt containing the memory usage, the CPU temperature, and the system uptime.
```

```
List the models installed on picocrush. Pick the smallest one. Write its name and size to a file called smallest-model.txt.
```

```
Show a progress bar in cyan going from 0 to 100 over 20 seconds. While it's running, check the CPU temperature every 5 seconds and include each reading in a file called temp-log.txt.
```

```
Create three files named a.txt, b.txt, and c.txt. Each file should contain its own filename as text. Then list the sandbox to confirm all three exist.
```

```
Tell me the current time, the uptime, the 5-minute load average, and the disk usage. Format it as a markdown table.
```

```
Celebrate a successful task: do a green success pulse, wait one second, then write a file called celebration.txt containing "completed at " followed by the current time.
```

---

## 💻 Code Tasks

`starcoder2:3b` is a dedicated code completion model and `qwen2.5:3b` is a strong general code model. Switch to either in ThreadWeaver's settings before running these.

```
Write a Python function that takes a list of numbers and returns the two largest without using sort() or max().
```

```
Explain what this regex does: ^(?:[a-zA-Z0-9_-]+\.)+[a-zA-Z]{2,}$
```

```
Write a bash script that shows the current CPU temperature and alerts if it's above 70°C.
```

```
Refactor this Python code to use a dictionary comprehension instead of a for loop:

result = {}
for key, value in items:
    if value > 0:
        result[key] = value * 2
```

---

## 🖼️ Vision Tasks

`llava:7b` is the best vision model installed. `moondream:1.8b` is much smaller and faster but less detailed. Switch to either, then upload an image via ThreadWeaver's attachment button.

```
Describe what you see in this image in two sentences.
```

```
What text is visible in this image? Just the text, no commentary.
```

```
Is there a cat in this image? Answer yes or no, then describe what you see.
```

```
Count the people in this image. If you can't be sure, give your best estimate.
```

---

## 🎓 Reasoning Tasks

`deepseek-r1:7b` is a strong reasoning model that shows its chain of thought. Switch to it for these.

```
A farmer has chickens and cows. There are 30 heads and 74 legs in total. How many chickens and how many cows does he have? Show your reasoning.
```

```
I need to schedule 5 meetings next week. Each meeting is 1 hour. I'm available Mon-Fri 9am-5pm, but not 12-1pm (lunch) and not Wednesday afternoon. How many possible schedules are there?
```

```
If a bat and a ball cost $1.10 in total, and the bat costs $1 more than the ball, how much does the ball cost? Explain your reasoning carefully before answering.
```

---

## 🤝 Combined External + Local

These work best with Claude/GPT-4/Gemini as the provider, showing how external models reach through to local tools. Switch providers in ThreadWeaver's settings, paste your API key, and try:

```
You have access to tools running on a Raspberry Pi 5 called picoclaw. Check the current temperature, memory, and uptime. Then write a brief human-friendly status message to a file called status.md. Finally, do a green success pulse on the LEDs to signal you're done.
```

```
I'm setting up this PicoClaw device for the first time. Walk me through a self-test: list the installed models on picocrush, check that the ThreadWeaver backend is healthy (via an HTTP call), verify the current time is correct, and flash the LEDs in the PicoClaw theme colors (purple → cyan → green). Report any problems.
```

```
Monitor picoclaw for the next 60 seconds. Every 10 seconds, check the CPU temperature and load. Show a progress bar based on time elapsed. If the temperature crosses 65°C, flash red and write an alert to alert.txt. Otherwise, do a success pulse at the end.
```

---

## ℹ️ Meta / Discovery

Use these to have the LLM explain its own capabilities.

```
What tools do you have available? Give me a one-line description of each.
```

```
What's the difference between the leds MCP server and the built-in tools?
```

```
Show me an example of using three different tools in one response.
```

```
You have a tool called get_temperature and a tool called set_led_color. Describe a scenario where you'd use both together.
```

---

## Troubleshooting Examples

If a prompt doesn't work:

- **Tool call silently skipped** — switch to `llama3.1:8b` or an external provider. Small models occasionally hallucinate that they called the tool without actually calling it.
- **"Tool not found"** — check the control panel MCP table; if a server is missing, restart ThreadWeaver with `sudo docker compose restart threadweaver`.
- **LEDs don't respond** — check `~/bin/pc-led color blue` directly; if that fails, the Blinkt! daemon (`picoclaw-leds`) isn't running. `sudo systemctl restart picoclaw-leds`.
- **File operations reject path** — the sandbox is `/tmp/picoclcaw-sandbox` inside the container; relative paths work (`greeting.txt`), absolute paths outside the sandbox are rejected.
- **Vision model says "I can't see the image"** — make sure you're on `llava:7b` or `moondream:1.8b` and that the image is attached (not just pasted as a link). Small models like `llama3.2:3b` don't have vision.

Share your favorite prompts with the PicoClaw community by opening a PR against [docs/examples.md](https://github.com/picocluster/PicoClaw/blob/main/docs/examples.md).
