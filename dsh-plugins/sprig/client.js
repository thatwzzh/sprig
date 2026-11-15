/**
 * DSH Client 插件：把「复制 / 引用 / 用知枝解释」合并到 DSH 原有的选词操作条。
 *
 * 做法：复用 message-quotes 的 selection 交互（由它 request.open() 打开 quote 表面），
 * 但把 key='quote' 的表面替换成同时包含三个操作的组件，避免右键时和原生 Copy 菜单叠在一起。
 */
window.__ModuleLoader__.load({
  id: 'dsh-plugin-sprig',
  factory(require) {
    const React = require('react')
    const h = React.createElement
    const BRIDGE = 'http://127.0.0.1:53917/v1/explain'

    // 只取用户/助手真实对话；system-reminder、技能清单、注入上下文不参与解释。
    const SYSTEM_REMINDER = /<system-reminder>[\s\S]*?<\/system-reminder>/gi
    const AVAILABLE_SKILLS = /<available_skills>[\s\S]*?<\/available_skills>/gi

    function cleanText(raw) {
      return String(raw || '')
        .replace(SYSTEM_REMINDER, '')
        .replace(AVAILABLE_SKILLS, '')
        .trim()
    }

    function nodeText(node) {
      if (!node) return ''
      if (node.kind === 'user' || node.kind === 'steering') {
        return cleanText((node.content || [])
          .filter(block => block && block.type === 'text' && typeof block.text === 'string')
          .map(block => block.text)
          .join('\n'))
      }
      if (node.kind === 'assistant') {
        return cleanText((node.blocks || [])
          .filter(block => block && block.kind === 'text' && typeof block.text === 'string')
          .map(block => block.text)
          .join('\n'))
      }
      // context（系统注入）、tool、command 等节点不是对话上下文
      return ''
    }

    function roleLabel(node) {
      if (!node) return '消息'
      if (node.kind === 'assistant') return '助手'
      return '用户'
    }

    function excerptAround(text, selection, limit) {
      if (text.length <= limit) return text
      const index = text.indexOf(selection)
      if (index < 0) return text.slice(0, limit) + '…'
      const before = Math.max(0, Math.floor((limit - selection.length) / 2))
      const start = Math.max(0, index - before)
      const head = start > 0 ? '…' : ''
      const tail = start + limit < text.length ? '…' : ''
      return head + text.slice(start, start + limit) + tail
    }

    function buildContext(nodes, selection) {
      const items = (nodes || [])
        .filter(node => node && (node.kind === 'user' || node.kind === 'steering' || node.kind === 'assistant'))
        .map(node => ({ node, text: nodeText(node) }))
        .filter(item => item.text.length > 0)

      if (items.length === 0) return ''
      const matched = items.findIndex(item => item.text.includes(selection))
      const center = matched >= 0 ? matched : items.length - 1
      const indexes = []
      if (center - 1 >= 0) indexes.push(center - 1)
      indexes.push(center)
      if (center + 1 < items.length) indexes.push(center + 1)

      const blocks = []
      let remaining = 1800
      for (const index of indexes) {
        if (remaining < 80) break
        const item = items[index]
        const selected = index === center
        const budget = Math.min(selected ? 1000 : 400, remaining - 20)
        const text = excerptAround(item.text, selection, budget)
        const block = `【${roleLabel(item.node)}】\n${text}`
        if (block.length <= remaining) {
          blocks.push(block)
          remaining -= block.length
        }
      }
      return blocks.join('\n\n').slice(0, 1800)
    }

    const baseButton = {
      height: 26,
      padding: '0 11px',
      borderRadius: 7,
      border: '1px solid var(--dsw-alias-border, rgba(127,127,127,.35))',
      background: 'var(--dsw-alias-bg-elevated, #fff)',
      color: 'var(--dsw-alias-text-primary, #111)',
      font: '12px -apple-system, system-ui, sans-serif',
      cursor: 'pointer',
      whiteSpace: 'nowrap',
    }

    function SelectionActions({ dismiss, readText, clearSelection, inputActions, useSession, useChat, sessionId }) {
      const enabled = useSession(s => !s.removed && (s.subagent === null || s.subagent.address.mode === 'continuable'))
      const nodes = useChat(snapshot => (snapshot && snapshot.legacy ? snapshot.legacy.nodes : []))
      const [busy, setBusy] = React.useState(false)
      const [message, setMessage] = React.useState('')

      React.useEffect(() => {
        if (!enabled) dismiss()
      }, [enabled, dismiss])
      if (!enabled) return null

      const currentText = () => {
        const text = readText()
        if (text === null || !text.trim()) {
          dismiss()
          return null
        }
        return text
      }

      const copy = async () => {
        const text = currentText()
        if (text === null) return
        try {
          await navigator.clipboard.writeText(text)
          clearSelection()
          dismiss()
        } catch (error) {
          setMessage('复制失败')
        }
      }

      const quote = () => {
        const text = currentText()
        if (text === null) return
        if (!inputActions.insertQuote(text)) {
          setMessage('当前会话不能引用')
          return
        }
        clearSelection()
        dismiss()
      }

      const explain = async () => {
        const selection = currentText()
        if (selection === null) return
        setBusy(true)
        setMessage('')
        try {
          const response = await fetch(BRIDGE, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              selection,
              context: buildContext(nodes, selection),
              title: 'DSH 对话',
              appName: 'DeepSeek Harness',
              sessionID: String(sessionId || ''),
              messageRole: 'assistant',
            }),
          })
          if (!response.ok) throw new Error(`HTTP ${response.status}`)
          clearSelection()
          dismiss()
        } catch (error) {
          setMessage('知枝未运行，或本机 bridge 被占用；先打开知枝再试')
          setBusy(false)
        }
      }

      return h('div', { style: { display: 'flex', alignItems: 'center', gap: 8 } },
        h('button', {
          type: 'button',
          style: baseButton,
          onPointerDown: event => event.preventDefault(),
          onClick: copy,
        }, '复制'),
        h('button', {
          type: 'button',
          style: baseButton,
          onPointerDown: event => event.preventDefault(),
          onClick: quote,
        }, '引用'),
        h('button', {
          type: 'button',
          style: { ...baseButton, fontWeight: 500 },
          disabled: busy,
          onPointerDown: event => event.preventDefault(),
          onClick: explain,
        }, busy ? '正在发送…' : '用知枝解释'),
        message ? h('span', { style: { fontSize: 11, opacity: 0.7, maxWidth: 260 } }, message) : null)
    }

    return {
      inject: ['slots'],
      apply(ctx) {
        // key 复用 quote：不新增表面，直接替换为三合一的选词操作条。
        ctx.slots.inject('conversation.chat.text-interaction', () => ctx.slots.register({
          name: 'conversation.chat.text-interaction',
          key: 'quote',
          // message-quotes 已以 priority 0 占了 quote；同一 key 必须用更低的 priority
          // 才能覆盖（slot 规则：数值越低越优先渲染）。
          priority: -10,
        }, SelectionActions))
      },
    }
  },
})
