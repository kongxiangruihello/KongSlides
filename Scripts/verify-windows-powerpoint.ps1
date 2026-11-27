param([Parameter(Mandatory=$true)][string]$File)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$path = (Resolve-Path $File).Path
$zip = [IO.Compression.ZipFile]::OpenRead($path)
function Read-XmlPart($name) {
    $entry = $zip.GetEntry($name)
    if ($null -eq $entry) { throw "Missing Open XML part: $name" }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { return [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
}
try {
    $slide = Read-XmlPart 'ppt/slides/slide1.xml'
    $notes = Read-XmlPart 'ppt/notesSlides/notesSlide1.xml'
    $ns = [Xml.XmlNamespaceManager]::new($slide.NameTable)
    $ns.AddNamespace('p', 'http://schemas.openxmlformats.org/presentationml/2006/main')
    $ns.AddNamespace('a', 'http://schemas.openxmlformats.org/drawingml/2006/main')
    if (!$slide.SelectSingleNode("//a:ea[@typeface='Microsoft YaHei']", $ns)) { throw 'Missing East Asian font' }
    if (!$slide.SelectSingleNode('//p:grpSp/p:cxnSp/p:nvCxnSpPr/p:cNvCxnSpPr/a:stCxn', $ns)) { throw 'Missing group attachment' }
    if (!$slide.SelectSingleNode("//a:tbl/a:tr/a:tc[@gridSpan='2']", $ns)) { throw 'Missing merged table cell' }
    if (!$notes.InnerText.Contains('教师讲稿验收')) { throw 'Missing speaker notes' }
    Write-Host 'Windows Open XML check passed: East Asian font, group, attached connector, merged cell and notes.'
} finally { $zip.Dispose() }

$officeType = [type]::GetTypeFromProgID('PowerPoint.Application')
if ($null -eq $officeType) {
    Write-Host 'PowerPoint desktop round-trip unavailable: Office is not installed on this runner.'
    exit 0
}
$office = [Activator]::CreateInstance($officeType)
try {
    $presentation = $office.Presentations.Open($path, -1, 0, 0)
    try {
        if ($presentation.Slides.Count -ne 1) { throw 'Unexpected slide count in PowerPoint' }
        $copy = Join-Path (Split-Path $path) 'PowerPoint-roundtrip.pptx'
        $presentation.SaveCopyAs($copy, 24)
        if (!(Test-Path $copy)) { throw 'PowerPoint did not produce a round-trip file' }
        Write-Host 'Windows PowerPoint opened and re-saved the fixture.'
    } finally { $presentation.Close() }
} finally { $office.Quit() }
