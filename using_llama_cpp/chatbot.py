from openai import OpenAI


client = OpenAI(
    base_url="http://localhost:8080/v1",
    api_key="not-needed",
)

MODEL = "lmstudio-community/Qwen3.5-4B-GGUF:Q4_K_M"


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

    stream = client.chat.completions.create(
        model=MODEL,
        messages=messages,
        temperature=0,
        max_tokens=500,
        stream=True,

        # llama-server supports reasoning control.
        extra_body={
            "reasoning": False
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
#   -hf lmstudio-community/Qwen3.5-4B-GGUF:Q4_K_M `
#   --reasoning off `
#   --ctx-size 4096 `
#   --threads 8 `
#   --port 8080