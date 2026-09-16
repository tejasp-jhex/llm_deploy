from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8080/v1",
    api_key="not-needed",
)

# Keep the model naming flexible; llama-server will default to its loaded model anyway
MODEL = "local-model"

messages = [
    {
        "role": "system",
        "content": (
            "You are a helpful AI assistant. "
            "Do not show or generate reasoning/thinking. "
            "Return only the final answer."
        ),
    }
]

while True:
    user_input = input("\nYou: ")

    if user_input.lower() in ["exit", "quit"]:
        print("Goodbye!")
        break

    messages.append({
        "role": "user",
        "content": user_input
    })

    print("\nAssistant: ", end="", flush=True)

    # Maximize speed via optimized payload parameters
    stream = client.chat.completions.create(
        model=MODEL,
        messages=messages,
        temperature=0,
        max_tokens=500,
        stream=True,
        extra_body={
            "reasoning": False,
            "cache_prompt": True,     # Forces llama-server to reuse previously parsed chat blocks
            "slot_id": 0              # Locks the conversation state into a single server slot
        }
    )

    assistant_response = ""

    for chunk in stream:
        if not chunk.choices:
            continue

        delta = chunk.choices[0].delta

        if delta.content:
            print(delta.content, end="", flush=True)
            assistant_response += delta.content

    print()

    messages.append({
        "role": "assistant",
        "content": assistant_response
    })



# llama-server `
#   -m "C:\Users\Tejas\.cache\huggingface\hub\models--lmstudio-community--Qwen3.5-4B-GGUF\snapshots\f9f88ac3e234be915e23811a6d28ea287bdb927e\Qwen3.5-4B-Q4_K_M.gguf" `
#   --reasoning off `
#   --ctx-size 2048 `
#   --threads 4 `
#   --n-gpu-layers 0 `
#   --flash-attn off `
#   --batch-size 32 `
#   --ubatch-size 32 `
#   --prio 3 `
#   --cont-batching `
#   --port 8080
