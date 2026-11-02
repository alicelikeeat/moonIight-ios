import Foundation

enum RPGOfficialStory {
    static let graph=RPGStoryGraph(id:"moonlight.official.v1",title:"月光：破碎世界",start:"prologue",nodes:[
        .init(id:"prologue",text:"序章 · 月核破碎\n月光落在陌生的地表。掌心的月核已裂成碎片，远处村庄仍亮着一盏灯。",next:"promise"),
        .init(id:"promise",kind:.choice,text:"你准备怎样开始？",choices:[
            .init(id:"help",text:"先帮村民修复家园",target:"help"),
            .init(id:"explore",text:"先寻找破碎的记忆",target:"explore")]),
        .init(id:"help",kind:.variable,next:"gather",actions:[.init(kind:.setVariable,key:"promise",value:1)]),
        .init(id:"explore",kind:.variable,next:"gather",actions:[.init(kind:.setVariable,key:"promise",value:2)]),
        .init(id:"gather",kind:.quest,text:"收集第一份材料\n走出出生地保护区，选择资源或自建方块并挖掘至破坏。",next:"prologueReward",condition:.init(kind:.event,key:"blockDestroyed"),actions:[.init(kind:.setQuest,key:"first-material",value:1)]),
        .init(id:"prologueReward",kind:.quest,next:"villageGate",actions:[.init(kind:.setQuest,key:"first-material",value:2),.init(kind:.giveItem,key:"wood",value:3)]),
        .init(id:"villageGate",kind:.condition,text:"第一章 · 失落的村庄\n沿预留通路抵达月光村，与守灯人交谈。工具里的任务导航会带你沿通路行走。",next:"keeper",condition:.init(kind:.nearAnchor,anchor:.village)),
        .init(id:"keeper",text:"守灯人：你也看见月核破碎了吗？神殿的两面仍连在一起。村口的旧守卫失去了方向，我们可以修理它，也可以让它安息。",next:"villageChoice"),
        .init(id:"villageChoice",kind:.choice,text:"如何处理失控守卫？",choices:[
            .init(id:"repair",text:"交出 2 块石材修理守卫",target:"repair",condition:.init(kind:.resource,key:"stone",value:2)),
            .init(id:"fight",text:"与守卫战斗，夺回村口",target:"guardFight")]),
        .init(id:"repair",kind:.world,next:"peaceEnding",actions:[.init(kind:.takeItem,key:"stone",value:2),.init(kind:.setVariable,key:"village-peace",value:1)]),
        .init(id:"guardFight",kind:.combat,text:"失控的守卫已出现。关闭剧情面板，用攻击、范围技能与翻滚击败它，再回来检查任务。",next:"battleEnding",condition:.init(kind:.enemyDefeated,key:"village-guardian"),actions:[.init(kind:.spawnEnemy,key:"village-guardian",value:45,anchor:.village)]),
        .init(id:"peaceEnding",kind:.quest,text:"守卫重新点亮了胸口的灯。守灯人把一块月晶交给你：下一段路，去双界神殿寻找另一面的记忆。",next:"chapterEnd",actions:[.init(kind:.giveItem,key:"moon-shard",value:1),.init(kind:.setQuest,key:"lost-village",value:2)]),
        .init(id:"battleEnding",kind:.quest,text:"守卫倒下，村口的道路恢复平静。守灯人收起残片：下一段路，去双界神殿寻找另一面的记忆。",next:"chapterEnd",actions:[.init(kind:.giveItem,key:"moon-shard",value:1),.init(kind:.setQuest,key:"lost-village",value:2)]),
        .init(id:"chapterEnd",kind:.end,text:"序章与第一章已完成\n村庄的灯火重新亮起。你可以继续探索双界，或在独立创作副本里编写自己的故事。")
    ])
}
