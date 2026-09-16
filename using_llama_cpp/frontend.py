import streamlit as st
import asyncio
from langchain_core.messages import HumanMessage, AIMessage
from langserve import RemoteRunnable

# ---------------------------------------------------------------------------
# 1. Page Configuration
# ---------------------------------------------------------------------------
st.set_page_config(
    page_title="Local LLM Chatbot",
    page_icon="🤖",
    layout="centered",
    initial_sidebar_state="expanded",
)

# ---------------------------------------------------------------------------
# 2. Hardcoded Endpoint Settings (Matches your server setup)
# ---------------------------------------------------------------------------
LANGSERVE_URL = "http://localhost:8000/chat"
# LANGSERVE_URL = "https://llama-server-80999039633.asia-south1.run.app/chat"
API_KEY = "your-super-secure-custom-api-key-here"


@st.cache_resource
def get_remote_chain():
    return RemoteRunnable(
        LANGSERVE_URL,
        headers={"x-api-key": API_KEY},
    )


remote_chain = get_remote_chain()

# ---------------------------------------------------------------------------
# 3. Session State
# ---------------------------------------------------------------------------
if "messages" not in st.session_state:
    st.session_state.messages = []

if "dark_mode" not in st.session_state:
    st.session_state.dark_mode = True

# ---------------------------------------------------------------------------
# 4. Theme CSS
# ---------------------------------------------------------------------------
def inject_css(dark: bool):
    if dark:
        bg = "#0e1117"
        bg_secondary = "#161a23"
        text = "#e8eaed"
        text_dim = "#9aa0a6"
        user_bubble = "linear-gradient(135deg, #5b6cff 0%, #7c4dff 100%)"
        user_text = "#ffffff"
        ai_bubble = "#1e222b"
        ai_border = "#2a2f3a"
        input_bg = "#1a1d24"
        accent = "#7c4dff"
        shadow = "0 4px 14px rgba(0,0,0,0.35)"
    else:
        bg = "#f7f8fb"
        bg_secondary = "#ffffff"
        text = "#1a1c23"
        text_dim = "#6b7280"
        user_bubble = "linear-gradient(135deg, #6d7bff 0%, #8f5bff 100%)"
        user_text = "#ffffff"
        ai_bubble = "#ffffff"
        ai_border = "#e5e7eb"
        input_bg = "#ffffff"
        accent = "#6d5bff"
        shadow = "0 4px 14px rgba(0,0,0,0.08)"

    code_bg = "#11141a" if dark else "#f1f2f6"
    code_text = "#e8eaed" if dark else "#1a1c23"

    st.markdown(
        f"""
        <style>
        /* Base app surface */
        .stApp, [data-testid="stAppViewContainer"], [data-testid="stMain"] {{
            background: {bg} !important;
            color: {text} !important;
        }}

        /* Top header bar + decoration strip */
        [data-testid="stHeader"] {{
            background: {bg} !important;
        }}
        [data-testid="stDecoration"] {{
            background: {user_bubble} !important;
        }}
        [data-testid="stToolbar"] {{
            color: {text} !important;
        }}
        [data-testid="stToolbar"] svg {{
            fill: {text} !important;
        }}

        /* Sidebar */
        [data-testid="stSidebar"] {{
            background: {bg_secondary} !important;
            border-right: 1px solid {ai_border};
        }}
        [data-testid="stSidebar"] * {{
            color: {text} !important;
        }}
        [data-testid="stSidebar"] [data-testid="stCaptionContainer"] * {{
            color: {text_dim} !important;
        }}
        [data-testid="stSidebarCollapseButton"] svg,
        [data-testid="stSidebarHeader"] svg,
        [data-testid="collapsedControl"] svg {{
            fill: {text} !important;
        }}

        .hero {{
            text-align: center;
            padding: 1.2rem 0 0.4rem 0;
        }}
        .hero h1 {{
            font-size: 1.9rem;
            font-weight: 800;
            margin: 0;
            background: {user_bubble};
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }}
        .hero p {{
            color: {text_dim} !important;
            margin-top: 0.2rem;
            font-size: 0.92rem;
        }}

        /* Chat message bubbles */
        [data-testid="stChatMessage"] {{
            background: transparent;
            padding: 0.15rem 0;
        }}

        [data-testid="stChatMessageContent"] {{
            border-radius: 18px;
            padding: 0.85rem 1.1rem;
            box-shadow: {shadow};
            line-height: 1.5;
            font-size: 0.95rem;
        }}

        /* User bubble — force every descendant to stay readable on the gradient */
        [data-testid="stChatMessage"]:has([data-testid="stChatMessageAvatarUser"]) [data-testid="stChatMessageContent"],
        [data-testid="stChatMessage"]:has([data-testid="stChatMessageAvatarUser"]) [data-testid="stChatMessageContent"] * {{
            background: {user_bubble};
            color: {user_text} !important;
        }}
        [data-testid="stChatMessage"]:has([data-testid="stChatMessageAvatarUser"]) [data-testid="stChatMessageContent"] {{
            border-top-right-radius: 4px;
        }}

        /* Assistant bubble — force every descendant to use the theme text color */
        [data-testid="stChatMessage"]:has([data-testid="stChatMessageAvatarAssistant"]) [data-testid="stChatMessageContent"],
        [data-testid="stChatMessage"]:has([data-testid="stChatMessageAvatarAssistant"]) [data-testid="stChatMessageContent"] p,
        [data-testid="stChatMessage"]:has([data-testid="stChatMessageAvatarAssistant"]) [data-testid="stChatMessageContent"] li,
        [data-testid="stChatMessage"]:has([data-testid="stChatMessageAvatarAssistant"]) [data-testid="stChatMessageContent"] span {{
            color: {text} !important;
        }}
        [data-testid="stChatMessage"]:has([data-testid="stChatMessageAvatarAssistant"]) [data-testid="stChatMessageContent"] {{
            background: {ai_bubble};
            border: 1px solid {ai_border};
            border-top-left-radius: 4px;
        }}

        /* Inline code / code blocks inside messages and captions */
        [data-testid="stChatMessageContent"] code,
        [data-testid="stCaptionContainer"] code,
        .stMarkdown code {{
            background: {code_bg} !important;
            color: {code_text} !important;
            border-radius: 4px;
        }}
        [data-testid="stChatMessageContent"] pre {{
            background: {code_bg} !important;
            border-radius: 10px;
        }}

        /* Chat input box */
        [data-testid="stChatInput"] {{
            background: {input_bg} !important;
            border-radius: 16px;
            border: 1px solid {ai_border};
        }}
        [data-testid="stChatInput"] textarea {{
            color: {text} !important;
            background: transparent !important;
        }}
        [data-testid="stChatInput"] textarea::placeholder {{
            color: {text_dim} !important;
        }}
        [data-testid="stChatInputSubmitButton"] svg {{
            fill: {text} !important;
        }}
        [data-testid="stBottomBlockContainer"] {{
            background: {bg} !important;
        }}

        /* Buttons */
        .stButton button {{
            background: {bg_secondary} !important;
            color: {text} !important;
            border: 1px solid {ai_border} !important;
            border-radius: 10px !important;
        }}
        .stButton button:hover {{
            border-color: {accent} !important;
            color: {accent} !important;
        }}

        /* Toggle switch track */
        [data-testid="stToggle"] label div[data-checked="true"] {{
            background-color: {accent} !important;
        }}

        /* Scrollbar */
        ::-webkit-scrollbar {{ width: 8px; }}
        ::-webkit-scrollbar-thumb {{ background: {ai_border}; border-radius: 8px; }}

        .status-pill {{
            display: inline-flex;
            align-items: center;
            gap: 6px;
            font-size: 0.78rem;
            color: {text_dim} !important;
            background: {bg_secondary};
            border: 1px solid {ai_border};
            padding: 4px 10px;
            border-radius: 999px;
        }}
        .status-pill * {{
            color: {text_dim} !important;
        }}
        .status-dot {{
            width: 7px; height: 7px; border-radius: 50%;
            background: #22c55e;
            box-shadow: 0 0 6px #22c55e;
        }}

        button[kind="secondary"] {{
            border-radius: 10px !important;
        }}
        </style>
        """,
        unsafe_allow_html=True,
    )


inject_css(st.session_state.dark_mode)

# ---------------------------------------------------------------------------
# 5. Sidebar
# ---------------------------------------------------------------------------
with st.sidebar:
    st.markdown("### ⚙️ Settings")

    toggled = st.toggle("🌙 Dark mode", value=st.session_state.dark_mode)
    if toggled != st.session_state.dark_mode:
        st.session_state.dark_mode = toggled
        st.rerun()

    st.markdown("---")
    st.markdown(
        f"""
        <div class="status-pill">
            <div class="status-dot"></div> Connected to local server
        </div>
        """,
        unsafe_allow_html=True,
    )
    st.caption(f"Endpoint: `{LANGSERVE_URL}`")

    st.markdown("---")
    if st.button("🗑️ Clear chat", use_container_width=True):
        st.session_state.messages = []
        st.rerun()

# ---------------------------------------------------------------------------
# 6. Header
# ---------------------------------------------------------------------------
st.markdown(
    """
    <div class="hero">
        <h1>🤖 Secure Local LLM Client</h1>
        <p>Powered by Qwen 2.5 · llama.cpp · LangServe</p>
    </div>
    """,
    unsafe_allow_html=True,
)

# ---------------------------------------------------------------------------
# 7. Redraw chat history
# ---------------------------------------------------------------------------
AVATAR_USER = "🧑"
AVATAR_AI = "🤖"

for message in st.session_state.messages:
    is_user = isinstance(message, HumanMessage)
    with st.chat_message("user" if is_user else "assistant",
                          avatar=AVATAR_USER if is_user else AVATAR_AI):
        st.markdown(message.content)

# ---------------------------------------------------------------------------
# 8. Async Token Streaming Driver Loop
# ---------------------------------------------------------------------------
async def stream_llm_response(payload, placeholder):
    assistant_text = ""
    try:
        async for chunk in remote_chain.astream(payload):
            assistant_text += chunk.content
            placeholder.markdown(assistant_text + "▌")
        placeholder.markdown(assistant_text)
    except Exception as e:
        placeholder.error(f"⚠️ Network error or invalid API key: {str(e)}")
        return None
    return assistant_text

# ---------------------------------------------------------------------------
# 9. Capture Live User Prompts
# ---------------------------------------------------------------------------
if user_input := st.chat_input("Ask your local AI model something..."):

    with st.chat_message("user", avatar=AVATAR_USER):
        st.markdown(user_input)

    st.session_state.messages.append(HumanMessage(content=user_input))

    with st.chat_message("assistant", avatar=AVATAR_AI):
        text_placeholder = st.empty()
        text_placeholder.markdown("_Thinking..._")

        input_payload = {"messages": st.session_state.messages}

        final_reply = asyncio.run(stream_llm_response(input_payload, text_placeholder))

        if final_reply:
            st.session_state.messages.append(AIMessage(content=final_reply))