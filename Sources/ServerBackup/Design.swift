import SwiftUI

// Shared visual system for the server workspace.
enum BackupTheme {
    static let background=Color(red:0.065,green:0.083,blue:0.105)
    static let sidebar=Color(red:0.085,green:0.105,blue:0.132)
    static let panel=Color(red:0.105,green:0.128,blue:0.157)
    static let border=Color.white.opacity(0.085)
    static let muted=Color(red:0.56,green:0.63,blue:0.72)
    static let blue=Color(red:0.19,green:0.48,blue:1)
}
struct BackupPanel<Content:View>:View {
    var title:String
    var subtitle:String=""
    var icon:String=""
    @ViewBuilder var content:Content
    var body:some View{VStack(alignment:.leading,spacing:16){
        if !title.isEmpty{HStack(alignment:.top,spacing:10){if !icon.isEmpty{Image(systemName:icon).foregroundStyle(BackupTheme.blue)};VStack(alignment:.leading,spacing:4){Text(title).font(.headline);if !subtitle.isEmpty{Text(subtitle).font(.caption).foregroundStyle(BackupTheme.muted)}};Spacer()}}
        content
    }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(BackupTheme.panel).clipShape(RoundedRectangle(cornerRadius:14)).overlay(RoundedRectangle(cornerRadius:14).stroke(BackupTheme.border))}
}
struct FieldLabel<Content:View>:View {
    let title:String
    @ViewBuilder var content:Content
    var body:some View{VStack(alignment:.leading,spacing:7){Text(title).font(.caption).foregroundStyle(BackupTheme.muted);content}.frame(maxWidth:.infinity,alignment:.leading)}
}
struct StatusBadge:View {
    let title:String
    var color:Color=BackupTheme.muted
    var body:some View{HStack(spacing:6){Circle().fill(color).frame(width:6,height:6);Text(title).font(.system(size:11,weight:.medium))}.padding(.horizontal,9).padding(.vertical,5).background(color.opacity(0.10)).clipShape(Capsule())}
}
struct WorkspaceIntro:View {
    let title:String
    let detail:String
    let icon:String
    var body:some View{HStack(spacing:14){Image(systemName:icon).font(.title2).foregroundStyle(BackupTheme.blue).frame(width:46,height:46).background(BackupTheme.blue.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius:12));VStack(alignment:.leading,spacing:5){Text(title).font(.title3.bold());Text(detail).font(.callout).foregroundStyle(BackupTheme.muted)};Spacer()}}
}
struct StepRow:View {
    let number:Int
    let title:String
    let detail:String
    let status:String
    let complete:Bool
    var enabled=true
    let action:()->Void
    var body:some View{Button(action:action){HStack(spacing:14){
        ZStack{RoundedRectangle(cornerRadius:10).fill(complete ? Color.green.opacity(0.12):BackupTheme.blue.opacity(0.12));if complete{Image(systemName:"checkmark").font(.headline).foregroundStyle(.green)}else{Text(String(number)).font(.headline).foregroundStyle(BackupTheme.blue)}}.frame(width:38,height:38)
        VStack(alignment:.leading,spacing:5){Text(title).font(.system(size:14,weight:.semibold)).foregroundStyle(.primary);Text(detail).font(.caption).foregroundStyle(BackupTheme.muted)}
        Spacer();StatusBadge(title:status,color:complete ? .green:BackupTheme.muted);Image(systemName:"chevron.right").font(.caption).foregroundStyle(BackupTheme.muted)
    }.padding(14).background(Color.white.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius:11))}.buttonStyle(.plain).disabled(!enabled)}
}
struct DirectorySelector:View {
    @EnvironmentObject var m:Model
    @Binding var sources:String
    @State private var path="/"
    @State private var entries:[[String:Any]]=[]
    @State private var loaded=false
    @State private var manual=false
    @State private var loading=false
    @State private var browseGeneration=UUID()
    var selected:Set<String>{Set(lines(sources))}
    var body:some View{VStack(alignment:.leading,spacing:12){
        HStack(spacing:8){Button{path=URL(fileURLWithPath:path).deletingLastPathComponent().path;browse() }label:{Image(systemName:"arrow.up")}.disabled(path=="/");TextField("Каталог сервера",text:$path).onSubmit{browse()};Button{browse()}label:{Image(systemName:"arrow.clockwise")}.disabled(loading);if loading{ProgressView().controlSize(.small)}}
        HStack{Text("Имя").frame(maxWidth:.infinity,alignment:.leading);Text("Тип").frame(width:75,alignment:.leading);Text("Действие").frame(width:60)}.font(.caption).foregroundStyle(BackupTheme.muted).padding(.horizontal,10)
        ScrollView{LazyVStack(spacing:0){if !loaded{VStack(spacing:12){Image(systemName:"folder").font(.largeTitle).foregroundStyle(BackupTheme.muted);Text("Откройте каталог сервера").foregroundStyle(BackupTheme.muted);Button("Загрузить папки"){browse()}.disabled(m.busy || m.probe.isEmpty)}.frame(maxWidth:.infinity).padding(.vertical,65)}
            ForEach(entries.indices,id:\.self){i in let e=entries[i];let value=e["path"] as? String ?? "";let directory=e["directory"] as? Bool==true
                HStack(spacing:9){Toggle("",isOn:Binding(get:{selected.contains(value)},set:{toggle(value,$0)})).labelsHidden().toggleStyle(BackupCheckboxStyle())
                    Button{if directory{path=value;browse()}}label:{HStack(spacing:9){Image(systemName:directory ? "folder.fill":"doc").foregroundStyle(directory ? .yellow:BackupTheme.muted);Text(e["name"] as? String ?? "").font(.system(size:13)).lineLimit(1);Spacer();Text(directory ? "Папка":"Файл").font(.caption).foregroundStyle(BackupTheme.muted).frame(width:75,alignment:.leading);Group{if directory{Image(systemName:"chevron.right")}else{Color.clear.frame(height:10)}}.frame(width:60)}.contentShape(Rectangle())}.buttonStyle(.plain)
                }.padding(.horizontal,10).padding(.vertical,9).background(selected.contains(value) ? BackupTheme.blue.opacity(0.17):(i.isMultiple(of:2) ? Color.white.opacity(0.02):.clear))

            }
        }}.frame(height:300).background(BackupTheme.background.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(BackupTheme.border))
        HStack{Text("Выбрано: \(selected.count)").font(.caption).foregroundStyle(BackupTheme.muted);Spacer();Button("Выбрать текущую папку"){toggle(path,true)}}
        if !selected.isEmpty{FlowSources(sources:$sources)}
        ClickableDisclosure(title:"Ввести пути вручную",isExpanded:$manual){TextEditor(text:$sources).font(.system(.caption,design:.monospaced)).frame(height:90).scrollContentBackground(.hidden).padding(8).background(BackupTheme.background).clipShape(RoundedRectangle(cornerRadius:8))}
    }.onAppear{if !loaded && !m.probe.isEmpty{browse()}}.onDisappear{browseGeneration=UUID();loading=false}}
    func toggle(_ value:String,_ include:Bool){var paths=lines(sources);if include{if !paths.contains(value){paths.append(value)}}else{paths.removeAll{$0==value}};sources=paths.joined(separator:"\n")}
    func browse(){guard let server=m.current else{return};let generation=UUID();browseGeneration=generation;loading=true;let requestedPath=path
        Task{do{let response=try await m.readLive(["action":"browse","path":requestedPath],server:server);guard browseGeneration==generation,m.selectedID==server.id else{return};entries=response as? [[String:Any]] ?? [];loaded=true;loading=false}catch{guard browseGeneration==generation else{return};loading=false;m.error=error.localizedDescription}}
    }
}
struct FlowSources:View {
    @Binding var sources:String
    var body:some View{VStack(spacing:5){ForEach(lines(sources),id:\.self){path in HStack{Image(systemName:"checkmark.circle.fill").foregroundStyle(.green);Text(path).font(.system(.caption,design:.monospaced)).lineLimit(1);Spacer();Button{sources=lines(sources).filter{$0 != path}.joined(separator:"\n")}label:{Image(systemName:"xmark")}.buttonStyle(.plain).foregroundStyle(BackupTheme.muted)}.padding(8).background(.white.opacity(0.03)).clipShape(RoundedRectangle(cornerRadius:7))}}}
}

struct BackupPrimaryButtonStyle:ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    func makeBody(configuration:Configuration)->some View {
        configuration.label.font(.system(size:13,weight:.semibold)).foregroundStyle(enabled ? .white:BackupTheme.muted)
            .padding(.horizontal,15).padding(.vertical,size == .large ? 11:8)
            .background(enabled ? BackupTheme.blue.opacity(configuration.isPressed ? 0.75:1):Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius:8))
    }
}

struct BackupCheckboxStyle:ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration)->some View {
        Button{configuration.isOn.toggle()}label:{HStack(spacing:9){
            RoundedRectangle(cornerRadius:4).fill(configuration.isOn ? BackupTheme.blue:Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius:4).stroke(configuration.isOn ? BackupTheme.blue:BackupTheme.muted.opacity(0.6)))
                .overlay{if configuration.isOn{Image(systemName:"checkmark").font(.system(size:10,weight:.bold)).foregroundStyle(.white)}}.frame(width:16,height:16)
            configuration.label
        }.contentShape(Rectangle()).opacity(enabled ? 1:0.5)}.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "Выбрано":"Не выбрано")
    }
}

struct ClickableDisclosure<Content:View>:View {
    let title:String
    @Binding var isExpanded:Bool
    @ViewBuilder var content:()->Content
    var body:some View{VStack(alignment:.leading,spacing:10){
        Button{isExpanded.toggle()}label:{HStack(spacing:8){Image(systemName:isExpanded ? "chevron.down":"chevron.right").font(.caption);Text(title);Spacer()}.contentShape(Rectangle())}.buttonStyle(.plain).accessibilityValue(isExpanded ? "Развёрнуто":"Свёрнуто")
        if isExpanded{content()}
    }}
}
