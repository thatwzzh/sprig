/* 知枝 Sprig — 官网交互
   无依赖。所有动效在 prefers-reduced-motion 下会自动降级。 */

(function () {
  'use strict';

  var reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ---------------------------- 主题 ---------------------------- */

  var root = document.documentElement;
  var themeBtn = document.getElementById('themeBtn');

  function setTheme(next) {
    root.dataset.theme = next;
    try { localStorage.setItem('sprig-theme', next); } catch (e) {}
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', next === 'dark' ? '#0C1310' : '#F6F1E6');
  }

  if (themeBtn) {
    themeBtn.addEventListener('click', function () {
      setTheme(root.dataset.theme === 'dark' ? 'light' : 'dark');
    });
  }

  /* ---------------------------- 导航滚动状态 ---------------------------- */

  var nav = document.getElementById('nav');
  if (nav) {
    var onScroll = function () {
      nav.classList.toggle('is-scrolled', window.scrollY > 8);
    };
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
  }

  /* ---------------------------- 滚动揭示 ---------------------------- */

  var reveals = Array.prototype.slice.call(document.querySelectorAll('.reveal'));

  // 同组元素错开一点，避免整块一起弹出来
  document.querySelectorAll('.detail-grid, .steps, .stats').forEach(function (group) {
    Array.prototype.forEach.call(group.children, function (child, i) {
      if (child.classList.contains('reveal')) {
        child.style.transitionDelay = (i * 80) + 'ms';
      }
    });
  });

  if ('IntersectionObserver' in window && !reduce) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('in');
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -6% 0px' });

    reveals.forEach(function (el) { io.observe(el); });
  } else {
    reveals.forEach(function (el) { el.classList.add('in'); });
  }

  /* ---------------------------- 数字滚动 ---------------------------- */

  var nums = Array.prototype.slice.call(document.querySelectorAll('.num'));

  function countUp(el) {
    var target = parseInt(el.dataset.count, 10) || 0;
    if (reduce || target === 0) { el.textContent = String(target); return; }
    var start = performance.now();
    var dur = 900;
    (function tick(now) {
      var p = Math.min(1, (now - start) / dur);
      var eased = 1 - Math.pow(1 - p, 3);
      el.textContent = String(Math.round(target * eased));
      if (p < 1) requestAnimationFrame(tick);
    })(start);
  }

  if ('IntersectionObserver' in window) {
    var numIO = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          countUp(entry.target);
          numIO.unobserve(entry.target);
        }
      });
    }, { threshold: 0.6 });
    nums.forEach(function (n) { numIO.observe(n); });
  } else {
    nums.forEach(function (n) { n.textContent = n.dataset.count; });
  }

  /* ---------------------------- 知识树沙盘 ---------------------------- */

  var CARDS = {
    rag: {
      crumb: 'RAG',
      title: 'RAG',
      body: 'RAG（检索增强生成）让模型先查资料再回答，而不是只靠参数里的记忆。它主要解决三件事：知识过期、幻觉、私有数据不能进训练集。'
    },
    hu: {
      crumb: 'RAG › 幻觉',
      title: '幻觉',
      body: '指模型编造看似合理、实际并不存在的内容，比如虚构的引用、数字和论文标题。选中这两个字按「解释」，就地拆开它。'
    },
    vec: {
      crumb: 'RAG › 向量数据库',
      title: '向量数据库',
      body: '把文本压成向量存起来，按语义相似度取回相关片段——RAG 的检索底座。'
    },
    fact: {
      crumb: 'RAG › 幻觉 › 事实性',
      title: '事实性',
      body: '幻觉的反面：每条结论都能追到出处，而不是听起来像真的。'
    },
    cite: {
      crumb: 'RAG › 幻觉 › 引用溯源',
      title: '引用溯源',
      body: '回答里每条结论都带来源编号，点开能看到原文——这是把「事实性」落到界面上的做法。'
    },
    recall: {
      crumb: 'RAG › 向量数据库 › 召回率',
      title: '召回率',
      body: '检索阶段取回的相关片段，占全部该取回的比例。召回不够，后面生成得再好也没用。'
    }
  };

  var treeCanvas = document.getElementById('treeCanvas');

  if (treeCanvas) {
    var nodes = Array.prototype.slice.call(treeCanvas.querySelectorAll('.tnode'));
    var crumb = document.getElementById('treeCrumb');
    var title = document.getElementById('treeTitle');
    var body = document.getElementById('treeBody');
    var tags = document.getElementById('treeTags');
    var resetBtn = document.getElementById('treeReset');

    var select = function (node) {
      nodes.forEach(function (n) { n.classList.toggle('is-active', n === node); });
      var data = CARDS[node.dataset.id];
      if (!data) return;
      crumb.textContent = data.crumb;
      title.textContent = data.title;
      body.textContent = data.body;

      // 祖先链：这张卡追问时到底带了什么上下文
      var chain = [];
      var cur = node;
      while (cur && cur.dataset.parent) {
        var pid = cur.dataset.parent;
        var parent = treeCanvas.querySelector('.tnode[data-id="' + pid + '"]');
        if (!parent || !CARDS[pid]) break;
        chain.unshift(CARDS[pid].title);
        cur = parent;
      }
      tags.textContent = chain.length ? '带上的祖先：' + chain.join(' › ') : '没有祖先 · 这是根';
    };

    var grow = function (id) {
      nodes.forEach(function (child) {
        if (child.dataset.parent !== id) return;
        if (!child.classList.contains('is-ghost')) return;
        // 先让连线变实，再让节点长出来
        var edge = treeCanvas.querySelector('[data-edge="' + id + '-' + child.dataset.id + '"]');
        if (edge) edge.classList.add('is-solid');
        setTimeout(function () {
          child.classList.remove('is-ghost');
          child.classList.add('just-grew');
          child.addEventListener('animationend', function handler() {
            child.classList.remove('just-grew');
            child.removeEventListener('animationend', handler);
          });
        }, 90);
      });
    };

    nodes.forEach(function (node) {
      var activate = function () {
        if (node.classList.contains('is-ghost')) return;
        select(node);
        grow(node.dataset.id);
      };
      node.addEventListener('click', activate);
      node.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          activate();
        }
      });
    });

    if (resetBtn) {
      resetBtn.addEventListener('click', function () {
        nodes.forEach(function (n) {
          if (n.dataset.id === 'cite' || n.dataset.id === 'recall') {
            n.classList.add('is-ghost');
            n.classList.remove('just-grew');
          }
        });
        treeCanvas.querySelectorAll('[data-edge="hu-cite"], [data-edge="vec-recall"]').forEach(function (e) {
          e.classList.remove('is-solid');
        });
        select(treeCanvas.querySelector('.tnode[data-id="rag"]'));
      });
    }
  }

  /* ---------------------------- agent 握手 ---------------------------- */

  var chipsBox = document.getElementById('agentChips');
  var hsBtn = document.getElementById('handshakeBtn');
  var hsReset = document.getElementById('handshakeReset');
  var note = document.getElementById('agentNote');

  if (chipsBox && hsBtn) {
    var chips = Array.prototype.slice.call(chipsBox.querySelectorAll('.agent-chip:not(.is-add)'));
    var baseNote = note ? note.textContent : '';
    var running = false;

    var clear = function () {
      chips.forEach(function (c) {
        c.classList.remove('is-ok', 'is-busy', 'is-warn');
        c.querySelector('.st').textContent = '○';
      });
      if (note) note.textContent = baseNote;
    };

    var run = function () {
      if (running) return;
      running = true;
      clear();
      var done = 0;

      chips.forEach(function (chip, i) {
        var st = chip.querySelector('.st');
        setTimeout(function () {
          chip.classList.add('is-busy');
          st.textContent = '◌';
        }, i * 260);

        setTimeout(function () {
          chip.classList.remove('is-busy');
          chip.classList.add('is-ok');
          st.textContent = '✓';
          done++;
          if (note) note.textContent = '握手 ' + done + '/' + chips.length + ' · 正在逐个测试';
          if (done === chips.length) {
            running = false;
            if (note) note.textContent = '全部通过 · 用你已有的订阅额度，不用另外买 Key';
          }
        }, i * 260 + 420 + i * 90);
      });
    };

    hsBtn.addEventListener('click', run);
    if (hsReset) {
      hsReset.addEventListener('click', function () {
        running = false;
        clear();
      });
    }
  }

  /* ---------------------------- 复制路径 ---------------------------- */

  document.querySelectorAll('.copy-btn').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var text = btn.dataset.copy || '';
      var label = btn.querySelector('span');
      var done = function () {
        if (!label) return;
        var old = label.textContent;
        label.textContent = '已复制';
        setTimeout(function () { label.textContent = old; }, 1600);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, done);
      } else {
        var ta = document.createElement('textarea');
        ta.value = text;
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand('copy'); } catch (e) {}
        document.body.removeChild(ta);
        done();
      }
    });
  });

  /* ---------------------------- 视频弹层 ---------------------------- */

  var modal = document.getElementById('videoModal');

  if (modal) {
    var video = modal.querySelector('video');
    var opener = null;

    var open = function (trigger) {
      opener = trigger || null;
      modal.hidden = false;
      document.body.style.overflow = 'hidden';
      if (video) {
        video.currentTime = 0;
        var p = video.play();
        if (p && p.catch) p.catch(function () {});
      }
      var closeBtn = modal.querySelector('.modal-close');
      if (closeBtn) closeBtn.focus();
    };

    var close = function () {
      modal.hidden = true;
      document.body.style.overflow = '';
      if (video) video.pause();
      if (opener) opener.focus();
    };

    document.querySelectorAll('[data-video]').forEach(function (btn) {
      btn.addEventListener('click', function () { open(btn); });
    });

    modal.querySelectorAll('[data-close]').forEach(function (el) {
      el.addEventListener('click', close);
    });

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && !modal.hidden) close();
    });
  }
})();
